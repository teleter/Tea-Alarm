import SwiftUI
import UserNotifications
import CloudKit

// MARK: - Analytics Manager
class AnalyticsManager: ObservableObject {
    @Published var snoozeCount: Int = 0
    @Published var dismissCount: Int = 0
    
    init() {
        loadAnalytics()
    }
    
    func recordSnooze() {
         snoozeCount += 1
         saveAnalytics()
    }
    
    func recordDismiss() {
         dismissCount += 1
         saveAnalytics()
    }
    
    private func saveAnalytics() {
         let defaults = UserDefaults.standard
         defaults.set(snoozeCount, forKey: "snoozeCount")
         defaults.set(dismissCount, forKey: "dismissCount")
    }
    
    private func loadAnalytics() {
         let defaults = UserDefaults.standard
         snoozeCount = defaults.integer(forKey: "snoozeCount")
         dismissCount = defaults.integer(forKey: "dismissCount")
    }
}

// MARK: - Notification Delegate for Interactive Actions
class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var analyticsManager: AnalyticsManager
    
    init(analyticsManager: AnalyticsManager) {
        self.analyticsManager = analyticsManager
    }
    
    // Handle user actions from notifications
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "SNOOZE_ACTION" {
            analyticsManager.recordSnooze()
            // In a complete app, identify the alarm and schedule a new snooze notification here.
        } else if response.actionIdentifier == "DISMISS_ACTION" {
            analyticsManager.recordDismiss()
            // Optionally cancel further notifications for that alarm.
        }
        completionHandler()
    }
}

// MARK: - Alarm Model
struct Alarm: Identifiable, Codable {
    var id = UUID()
    var time: Date
    var timeZoneIdentifier: String
    var label: String
    var notificationSubtitle: String
    var repeatDays: [Int]  // Weekday numbers (1 = Sunday, 2 = Monday, …, 7 = Saturday)
}

// MARK: - Alarm Manager with CloudKit, Notifications, Analytics, and Error Handling
class AlarmManager: ObservableObject {
    @Published var alarms: [Alarm] = [] {
        didSet {
            saveAlarms()
            // Sync to iCloud when local data changes.
            syncAlarmsToCloud()
        }
    }
    @Published var errorMessage: String? = nil
    
    private let alarmsFile = "alarms.json"
    let privateDatabase = CKContainer.default().privateCloudDatabase
    
    init() {
        registerNotificationCategories()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = "Notification permission error: \(error.localizedDescription)"
                }
            }
        }
        loadAlarms()
        fetchAlarmsFromCloud()
    }
    
    /// Registers the notification category with custom actions.
    private func registerNotificationCategories() {
        let snoozeAction = UNNotificationAction(identifier: "SNOOZE_ACTION", title: "Snooze", options: [])
        let dismissAction = UNNotificationAction(identifier: "DISMISS_ACTION", title: "Dismiss", options: [.destructive])
        let category = UNNotificationCategory(identifier: "TEA_TIME_CATEGORY", actions: [snoozeAction, dismissAction], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
    
    func addAlarm(time: Date, timeZoneIdentifier: String, label: String, notificationSubtitle: String, repeatDays: [Int]) {
        let subtitle = notificationSubtitle.isEmpty ? "Time to Sip Tea!" : notificationSubtitle
        let alarm = Alarm(time: time, timeZoneIdentifier: timeZoneIdentifier, label: label, notificationSubtitle: subtitle, repeatDays: repeatDays)
        alarms.append(alarm)
        scheduleNotification(for: alarm)
        donateCreateAlarmShortcut(for: alarm)
        uploadAlarmToCloud(alarm: alarm)
    }
    
    /// Donates a Siri shortcut via NSUserActivity.
    private func donateCreateAlarmShortcut(for alarm: Alarm) {
        let activity = NSUserActivity(activityType: "com.example.TeaTimeAlarm.createAlarm")
        activity.title = "Create Tea Time Alarm"
        activity.userInfo = [
            "id": alarm.id.uuidString,
            "time": alarm.time,
            "timeZoneIdentifier": alarm.timeZoneIdentifier,
            "label": alarm.label,
            "notificationSubtitle": alarm.notificationSubtitle,
            "repeatDays": alarm.repeatDays
        ]
        activity.isEligibleForSearch = true
        activity.isEligibleForPrediction = true
        activity.persistentIdentifier = NSUserActivityPersistentIdentifier(alarm.id.uuidString)
        activity.suggestedInvocationPhrase = "Set my tea time alarm"
        activity.becomeCurrent()
    }
    
    /// Schedules a notification for the alarm on each selected weekday,
    /// plus a reminder notification 5 minutes before the alarm.
    func scheduleNotification(for alarm: Alarm) {
        let content = UNMutableNotificationContent()
        content.title = "Tea Time Alarm"
        content.subtitle = alarm.notificationSubtitle
        content.body = alarm.label
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = "TEA_TIME_CATEGORY"
        
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: alarm.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        let timeComponents = calendar.dateComponents([.hour, .minute], from: alarm.time)
        
        for day in alarm.repeatDays {
            var dateComponents = DateComponents()
            dateComponents.weekday = day
            dateComponents.hour = timeComponents.hour
            dateComponents.minute = timeComponents.minute
            dateComponents.timeZone = calendar.timeZone
            
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let requestID = "\(alarm.id.uuidString)_\(day)"
            let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    DispatchQueue.main.async {
                        self.errorMessage = "Error scheduling notification for \(alarm.label) on weekday \(day): \(error.localizedDescription)"
                    }
                }
            }
            
            // Schedule a reminder notification 5 minutes before the alarm.
            var reminderComponents = dateComponents
            if let minute = reminderComponents.minute {
                if minute >= 5 {
                    reminderComponents.minute = minute - 5
                } else {
                    reminderComponents.minute = 0
                }
            }
            let reminderContent = UNMutableNotificationContent()
            reminderContent.title = "Tea Preparation Reminder"
            reminderContent.body = "Your tea will be ready in 5 minutes. Get ready to brew!"
            reminderContent.sound = UNNotificationSound.default
            let reminderTrigger = UNCalendarNotificationTrigger(dateMatching: reminderComponents, repeats: true)
            let reminderRequestID = "\(alarm.id.uuidString)_reminder_\(day)"
            let reminderRequest = UNNotificationRequest(identifier: reminderRequestID, content: reminderContent, trigger: reminderTrigger)
            UNUserNotificationCenter.current().add(reminderRequest) { error in
                if let error = error {
                    DispatchQueue.main.async {
                        self.errorMessage = "Error scheduling reminder for \(alarm.label) on weekday \(day): \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    func removeAlarm(at offsets: IndexSet) {
        offsets.forEach { index in
            let alarm = alarms[index]
            for day in alarm.repeatDays {
                let requestID = "\(alarm.id.uuidString)_\(day)"
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestID])
                let reminderRequestID = "\(alarm.id.uuidString)_reminder_\(day)"
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderRequestID])
            }
            deleteAlarmFromCloud(alarm: alarm)
        }
        alarms.remove(atOffsets: offsets)
    }
    
    // MARK: - Persistence Methods
    
    private func alarmsFileURL() -> URL? {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documents.appendingPathComponent(alarmsFile)
    }
    
    private func saveAlarms() {
        guard let url = alarmsFileURL() else { return }
        do {
            let data = try JSONEncoder().encode(alarms)
            try data.write(to: url)
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Error saving alarms: \(error.localizedDescription)"
            }
        }
    }
    
    private func loadAlarms() {
        guard let url = alarmsFileURL(), FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([Alarm].self, from: data)
            alarms = decoded
            alarms.forEach { scheduleNotification(for: $0) }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Error loading alarms: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - CloudKit Sync Methods
    
    func uploadAlarmToCloud(alarm: Alarm) {
        let record = CKRecord(recordType: "Alarm", recordID: CKRecord.ID(recordName: alarm.id.uuidString))
        record["time"] = alarm.time as CKRecordValue
        record["timeZoneIdentifier"] = alarm.timeZoneIdentifier as CKRecordValue
        record["label"] = alarm.label as CKRecordValue
        record["notificationSubtitle"] = alarm.notificationSubtitle as CKRecordValue
        record["repeatDays"] = alarm.repeatDays as CKRecordValue
        
        privateDatabase.save(record) { savedRecord, error in
            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = "Error uploading alarm to iCloud: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func deleteAlarmFromCloud(alarm: Alarm) {
        let recordID = CKRecord.ID(recordName: alarm.id.uuidString)
        privateDatabase.delete(withRecordID: recordID) { recordID, error in
            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = "Error deleting alarm from iCloud: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func syncAlarmsToCloud() {
        alarms.forEach { uploadAlarmToCloud(alarm: $0) }
    }
    
    func fetchAlarmsFromCloud() {
        let query = CKQuery(recordType: "Alarm", predicate: NSPredicate(value: true))
        privateDatabase.perform(query, inZoneWith: nil) { records, error in
            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = "Error fetching alarms from iCloud: \(error.localizedDescription)"
                }
                return
            }
            if let records = records {
                var fetchedAlarms: [Alarm] = []
                for record in records {
                    if let time = record["time"] as? Date,
                       let timeZoneIdentifier = record["timeZoneIdentifier"] as? String,
                       let label = record["label"] as? String,
                       let notificationSubtitle = record["notificationSubtitle"] as? String,
                       let repeatDays = record["repeatDays"] as? [Int] {
                        let alarm = Alarm(id: UUID(uuidString: record.recordID.recordName) ?? UUID(),
                                          time: time,
                                          timeZoneIdentifier: timeZoneIdentifier,
                                          label: label,
                                          notificationSubtitle: notificationSubtitle,
                                          repeatDays: repeatDays)
                        fetchedAlarms.append(alarm)
                    }
                }
                DispatchQueue.main.async {
                    self.alarms = fetchedAlarms
                    fetchedAlarms.forEach { self.scheduleNotification(for: $0) }
                }
            }
        }
    }
}

// MARK: - UI Views

// A row displaying alarm details.
struct AlarmRowView: View {
    var alarm: Alarm
    
    func formattedTime(for alarm: Alarm) -> String {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: alarm.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.hour, .minute], from: alarm.time)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
    
    func weekdayNames(for repeatDays: [Int]) -> String {
        let formatter = DateFormatter()
        let symbols = formatter.shortWeekdaySymbols
        let names = repeatDays.sorted().map { symbols[$0 - 1] }
        return names.joined(separator: ", ")
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(alarm.label)
                    .font(.headline)
                Text("Time: \(formattedTime(for: alarm))")
                    .font(.subheadline)
                Text("Time Zone: \(alarm.timeZoneIdentifier)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Repeats on: \(weekdayNames(for: alarm.repeatDays))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 2)
    }
}

// A view to add a new alarm.
struct AddAlarmView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedTime: Date = Date()
    @State private var selectedTimeZone: String = "GMT"
    @State private var alarmLabel: String = ""
    @State private var notificationSubtitle: String = ""
    @State private var selectedDays: Set<Int> = []
    
    let timeZones = TimeZone.knownTimeZoneIdentifiers.sorted()
    let weekDays: [(name: String, number: Int)] = [
        ("Sunday", 1),
        ("Monday", 2),
        ("Tuesday", 3),
        ("Wednesday", 4),
        ("Thursday", 5),
        ("Friday", 6),
        ("Saturday", 7)
    ]
    
    var onAdd: (Date, String, String, String, [Int]) -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Alarm Details")) {
                    DatePicker("Select Time", selection: $selectedTime, displayedComponents: [.hourAndMinute])
                    Picker("Time Zone", selection: $selectedTimeZone) {
                        ForEach(timeZones, id: \.self) { tz in
                            Text(tz).tag(tz)
                        }
                    }
                    TextField("Alarm Label", text: $alarmLabel)
                        .disableAutocorrection(true)
                }
                Section(header: Text("Notification Details")) {
                    TextField("Notification Subtitle", text: $notificationSubtitle)
                        .disableAutocorrection(true)
                }
                Section(header: Text("Repeat Days")) {
                    ForEach(weekDays, id: \.number) { day in
                        Toggle(day.name, isOn: Binding(
                            get: { selectedDays.contains(day.number) },
                            set: { newValue in
                                if newValue { selectedDays.insert(day.number) }
                                else { selectedDays.remove(day.number) }
                            }
                        ))
                    }
                }
            }
            .navigationTitle("Add Alarm")
            .navigationBarItems(leading: Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            }, trailing: Button("Save") {
                let labelText = alarmLabel.isEmpty ? "Tea Time" : alarmLabel
                let days = selectedDays.isEmpty ? [1,2,3,4,5,6,7] : Array(selectedDays)
                onAdd(selectedTime, selectedTimeZone, labelText, notificationSubtitle, days)
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

// A calendar view for visualizing recurring alarms.
struct CalendarView: View {
    @ObservedObject var alarmManager: AlarmManager
    @State private var currentDate: Date = Date()
    
    func alarmsFor(date: Date) -> [Alarm] {
        let weekday = Calendar.current.component(.weekday, from: date)
        return alarmManager.alarms.filter { $0.repeatDays.contains(weekday) }
    }
    
    func generateDays(for date: Date) -> [Date?] {
        var days: [Date?] = []
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let firstOfMonth = calendar.date(from: components) else { return days }
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        for _ in 1..<weekday { days.append(nil) }
        let range = calendar.range(of: .day, in: .month, for: firstOfMonth)!
        for day in range {
            if let d = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                days.append(d)
            }
        }
        return days
    }
    
    func monthYearString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date)
    }
    
    func previousMonth(from date: Date) -> Date {
        return Calendar.current.date(byAdding: .month, value: -1, to: date) ?? date
    }
    
    func nextMonth(from date: Date) -> Date {
        return Calendar.current.date(byAdding: .month, value: 1, to: date) ?? date
    }
    
    var body: some View {
        VStack {
            HStack {
                Button(action: { currentDate = previousMonth(from: currentDate) }) {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                Text(monthYearString(for: currentDate))
                    .font(.headline)
                Spacer()
                Button(action: { currentDate = nextMonth(from: currentDate) }) {
                    Image(systemName: "chevron.right")
                }
            }
            .padding()
            
            let weekDays = Calendar.current.shortWeekdaySymbols
            HStack {
                ForEach(weekDays, id: \.self) { day in
                    Text(day)
                        .frame(maxWidth: .infinity)
                        .font(.subheadline)
                }
            }
            
            let days = generateDays(for: currentDate)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7)) {
                ForEach(days, id: \.self) { date in
                    if let date = date {
                        DayCellView(date: date, alarms: alarmsFor(date: date), alarmManager: alarmManager)
                    } else {
                        Text("")
                    }
                }
            }
            .padding()
            
            Spacer()
        }
    }
}

// A single day cell in the calendar.
struct DayCellView: View {
    var date: Date
    var alarms: [Alarm]
    @ObservedObject var alarmManager: AlarmManager
    @State private var showAlarms = false
    
    var body: some View {
        Button(action: { showAlarms = true }) {
            VStack {
                Text("\(Calendar.current.component(.day, from: date))")
                    .foregroundColor(alarms.isEmpty ? .primary : .blue)
                if !alarms.isEmpty {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(4)
        }
        .sheet(isPresented: $showAlarms) {
            AlarmListForDateView(date: date, alarms: alarms)
        }
    }
}

// A view listing alarms for a specific day.
struct AlarmListForDateView: View {
    var date: Date
    var alarms: [Alarm]
    @Environment(\.presentationMode) var presentationMode
    
    func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
    
    func formattedTime(for alarm: Alarm) -> String {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: alarm.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.hour, .minute], from: alarm.time)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
    
    var body: some View {
        NavigationView {
            List(alarms, id: \.id) { alarm in
                VStack(alignment: .leading) {
                    Text(alarm.label)
                        .font(.headline)
                    Text("Time: \(formattedTime(for: alarm))")
                        .font(.subheadline)
                }
            }
            .navigationTitle("Alarms on \(formattedDate(date))")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

// A simple analytics summary view.
struct AnalyticsView: View {
    @ObservedObject var analyticsManager: AnalyticsManager
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Analytics Summary")
                    .font(.title)
                HStack {
                    Text("Snoozed Alarms:")
                    Spacer()
                    Text("\(analyticsManager.snoozeCount)")
                }
                .padding()
                HStack {
                    Text("Dismissed Alarms:")
                    Spacer()
                    Text("\(analyticsManager.dismissCount)")
                }
                .padding()
                Spacer()
            }
            .padding()
            .navigationTitle("Analytics")
        }
    }
}

// Main ContentView with a TabView for Alarms, Calendar, and Analytics.
struct ContentView: View {
    @ObservedObject var alarmManager = AlarmManager()
    @ObservedObject var analyticsManager = AnalyticsManager()
    @State private var showingAddAlarm = false
    
    var body: some View {
        TabView {
            NavigationView {
                ZStack {
                    LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.1), Color.white]),
                                   startPoint: .top,
                                   endPoint: .bottom)
                        .edgesIgnoringSafeArea(.all)
                    
                    VStack {
                        if alarmManager.alarms.isEmpty {
                            Text("No alarms set yet.\nTap the + button to add one.")
                                .multilineTextAlignment(.center)
                                .foregroundColor(.secondary)
                                .padding()
                        } else {
                            List {
                                ForEach(alarmManager.alarms) { alarm in
                                    AlarmRowView(alarm: alarm)
                                        .listRowBackground(Color.clear)
                                }
                                .onDelete(perform: alarmManager.removeAlarm)
                            }
                            .listStyle(PlainListStyle())
                        }
                    }
                    .padding()
                }
                .navigationTitle("Tea Time Alarms")
                .navigationBarItems(trailing: Button(action: {
                    showingAddAlarm = true
                }) {
                    Image(systemName: "plus")
                })
                .sheet(isPresented: $showingAddAlarm) {
                    AddAlarmView { time, timezone, label, subtitle, repeatDays in
                        alarmManager.addAlarm(time: time,
                                              timeZoneIdentifier: timezone,
                                              label: label,
                                              notificationSubtitle: subtitle,
                                              repeatDays: repeatDays)
                    }
                }
                .alert(isPresented: Binding<Bool>(
                    get: { alarmManager.errorMessage != nil },
                    set: { newValue in if !newValue { alarmManager.errorMessage = nil } }
                )) {
                    Alert(title: Text("Error"),
                          message: Text(alarmManager.errorMessage ?? "An unknown error occurred."),
                          dismissButton: .default(Text("OK")))
                }
            }
            .tabItem {
                Label("Alarms", systemImage: "alarm")
            }
            
            NavigationView {
                CalendarView(alarmManager: alarmManager)
                    .navigationTitle("Calendar")
            }
            .tabItem {
                Label("Calendar", systemImage: "calendar")
            }
            
            AnalyticsView(analyticsManager: analyticsManager)
                .tabItem {
                    Label("Analytics", systemImage: "chart.bar")
                }
        }
    }
}

// MARK: - App Entry Point
@main
struct TeaTimeAlarmApp: App {
    @StateObject var analyticsManager = AnalyticsManager()
    
    init() {
        // Set the UNUserNotificationCenter delegate for handling interactive actions.
        UNUserNotificationCenter.current().delegate = NotificationDelegate(analyticsManager: analyticsManager)
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
