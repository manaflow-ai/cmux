import AppKit
import Foundation
import UserNotifications

// UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers:) and
// removePendingNotificationRequests(withIdentifiers:) perform synchronous XPC to
// usernoted under the hood. When usernoted is slow, this blocks the calling thread
// indefinitely. These helpers dispatch the calls off the main thread so they never
// freeze the UI.
extension UNUserNotificationCenter {
    private static let removalQueue = DispatchQueue(
        label: "com.cmuxterm.notification-removal",
        qos: .utility
    )

    func removeDeliveredNotificationsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func removePendingNotificationRequestsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

enum NotificationSoundSettings {
    static let key = "notificationSound"
    static let defaultValue = "default"
    static let customFileValue = "custom_file"
    static let customFilePathKey = "notificationSoundCustomFilePath"
    static let defaultCustomFilePath = ""
    private static let stagedCustomSoundBaseName = "cmux-custom-notification-sound"
    static let customCommandKey = "notificationCustomCommand"
    static let defaultCustomCommand = ""

    static let systemSounds: [(label: String, value: String)] = [
        ("Default", "default"),
        ("Basso", "Basso"),
        ("Blow", "Blow"),
        ("Bottle", "Bottle"),
        ("Frog", "Frog"),
        ("Funk", "Funk"),
        ("Glass", "Glass"),
        ("Hero", "Hero"),
        ("Morse", "Morse"),
        ("Ping", "Ping"),
        ("Pop", "Pop"),
        ("Purr", "Purr"),
        ("Sosumi", "Sosumi"),
        ("Submarine", "Submarine"),
        ("Tink", "Tink"),
        ("Custom File...", customFileValue),
        ("None", "none"),
    ]

    static func sound(defaults: UserDefaults = .standard) -> UNNotificationSound? {
        let value = defaults.string(forKey: key) ?? defaultValue
        switch value {
        case "default":
            return .default
        case "none":
            return nil
        case customFileValue:
            guard let customSoundName = stagedCustomSoundName(defaults: defaults) else {
                return nil
            }
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: customSoundName))
        default:
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: value))
        }
    }

    static func usesSystemSound(defaults: UserDefaults = .standard) -> Bool {
        let value = defaults.string(forKey: key) ?? defaultValue
        switch value {
        case "none":
            return false
        case customFileValue:
            return customFileURL(defaults: defaults) != nil
        default:
            return true
        }
    }

    static func isSilent(defaults: UserDefaults = .standard) -> Bool {
        return (defaults.string(forKey: key) ?? defaultValue) == "none"
    }

    static func isCustomFileSelected(defaults: UserDefaults = .standard) -> Bool {
        (defaults.string(forKey: key) ?? defaultValue) == customFileValue
    }

    static func stagedCustomSoundName(defaults: UserDefaults = .standard) -> String? {
        guard let sourceURL = customFileURL(defaults: defaults) else { return nil }
        let sourceExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceExtension.isEmpty else {
            NSLog("Notification custom sound requires a file extension: \(sourceURL.path)")
            return nil
        }

        let destinationDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        let destinationFileName = "\(stagedCustomSoundBaseName).\(sourceExtension.lowercased())"
        let destinationURL = destinationDirectory.appendingPathComponent(destinationFileName, isDirectory: false)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try copyStagedSoundIfNeeded(from: sourceURL, to: destinationURL, fileManager: fileManager)
            try cleanupStaleStagedSoundFiles(
                in: destinationDirectory,
                keeping: destinationFileName,
                preservingSourceURL: sourceURL,
                fileManager: fileManager
            )
            return destinationFileName
        } catch {
            NSLog("Failed to stage custom notification sound: \(error)")
            return nil
        }
    }

    static func customFileURL(defaults: UserDefaults = .standard) -> URL? {
        guard let path = normalizedCustomFilePath(defaults.string(forKey: customFilePathKey) ?? defaultCustomFilePath) else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func playCustomFileSound(defaults: UserDefaults = .standard) {
        guard let url = customFileURL(defaults: defaults) else { return }
        playSoundFile(at: url)
    }

    static func playCustomFileSound(path: String) {
        guard let normalizedPath = normalizedCustomFilePath(path) else { return }
        let url = URL(fileURLWithPath: (normalizedPath as NSString).expandingTildeInPath)
        playSoundFile(at: url)
    }

    static func previewSound(value: String, defaults: UserDefaults = .standard) {
        switch value {
        case "default":
            NSSound.beep()
        case "none":
            break
        case customFileValue:
            playCustomFileSound(defaults: defaults)
        default:
            NSSound(named: NSSound.Name(value))?.play()
        }
    }

    private static func normalizedCustomFilePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func playSoundFile(at url: URL) {
        DispatchQueue.main.async {
            guard let sound = NSSound(contentsOf: url, byReference: false) else {
                NSLog("Notification custom sound failed to load from path: \(url.path)")
                return
            }
            sound.play()
        }
    }

    private static func cleanupStaleStagedSoundFiles(
        in directoryURL: URL,
        keeping fileName: String,
        preservingSourceURL: URL,
        fileManager: FileManager
    ) throws {
        let prefix = "\(stagedCustomSoundBaseName)."
        let normalizedSource = preservingSourceURL.standardizedFileURL
        for fileNameCandidate in try fileManager.contentsOfDirectory(atPath: directoryURL.path) {
            guard fileNameCandidate.hasPrefix(prefix), fileNameCandidate != fileName else { continue }
            let staleURL = directoryURL.appendingPathComponent(fileNameCandidate, isDirectory: false)
            if staleURL.standardizedFileURL == normalizedSource {
                continue
            }
            try? fileManager.removeItem(at: staleURL)
        }
    }

    private static func copyStagedSoundIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let normalizedSource = sourceURL.standardizedFileURL
        let normalizedDestination = destinationURL.standardizedFileURL
        guard normalizedSource != normalizedDestination else { return }

        if fileManager.fileExists(atPath: normalizedDestination.path) {
            let sourceAttributes = try fileManager.attributesOfItem(atPath: normalizedSource.path)
            let destinationAttributes = try fileManager.attributesOfItem(atPath: normalizedDestination.path)
            let sourceSize = sourceAttributes[.size] as? NSNumber
            let destinationSize = destinationAttributes[.size] as? NSNumber
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            if sourceSize == destinationSize && sourceDate == destinationDate {
                return
            }
            try fileManager.removeItem(at: normalizedDestination)
        }

        try fileManager.copyItem(at: normalizedSource, to: normalizedDestination)
    }

    private static let customCommandQueue = DispatchQueue(
        label: "com.cmuxterm.notification-custom-command",
        qos: .utility
    )

    static func runCustomCommand(title: String, subtitle: String, body: String, defaults: UserDefaults = .standard) {
        let command = (defaults.string(forKey: customCommandKey) ?? defaultCustomCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        customCommandQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            env["CMUX_NOTIFICATION_TITLE"] = title
            env["CMUX_NOTIFICATION_SUBTITLE"] = subtitle
            env["CMUX_NOTIFICATION_BODY"] = body
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                NSLog("Notification command failed to launch: \(error)")
            }
        }
    }
}

enum NotificationBadgeSettings {
    static let dockBadgeEnabledKey = "notificationDockBadgeEnabled"
    static let defaultDockBadgeEnabled = true

    static func isDockBadgeEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: dockBadgeEnabledKey) == nil {
            return defaultDockBadgeEnabled
        }
        return defaults.bool(forKey: dockBadgeEnabledKey)
    }
}

enum TaggedRunBadgeSettings {
    static let environmentKey = "CMUX_TAG"
    private static let maxTagLength = 10

    static func normalizedTag(from env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        normalizedTag(env[environmentKey])
    }

    static func normalizedTag(_ rawTag: String?) -> String? {
        guard var tag = rawTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
            return nil
        }
        if tag.count > maxTagLength {
            tag = String(tag.prefix(maxTagLength))
        }
        return tag
    }
}

enum AppFocusState {
    static var overrideIsFocused: Bool?

    static func isAppActive() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        return NSApp.isActive
    }

    static func isAppFocused() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        guard NSApp.isActive else { return false }
        guard let keyWindow = NSApp.keyWindow, keyWindow.isKeyWindow else { return false }
        // Only treat the app as "focused" for notification suppression when a main terminal window
        // is key. If Settings/About/debug panels are key, we still want notifications to show.
        if let raw = keyWindow.identifier?.rawValue {
            return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
        }
        return false
    }
}

enum NotificationAuthorizationState: Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral

    var statusLabel: String {
        switch self {
        case .unknown, .notDetermined:
            return "Not Requested"
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .provisional:
            return "Deliver Quietly"
        case .ephemeral:
            return "Temporary"
        }
    }

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .unknown, .notDetermined, .denied:
            return false
        }
    }
}

struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
}

@MainActor
final class TerminalNotificationStore: ObservableObject {
    private struct TabSurfaceKey: Hashable {
        let tabId: UUID
        let surfaceId: UUID?
    }

    private struct NotificationIndexes {
        var unreadCount = 0
        var unreadCountByTabId: [UUID: Int] = [:]
        var unreadByTabSurface = Set<TabSurfaceKey>()
        var latestUnreadByTabId: [UUID: TerminalNotification] = [:]
        var latestByTabId: [UUID: TerminalNotification] = [:]
    }

    static let shared = TerminalNotificationStore()

    static let categoryIdentifier = "com.cmuxterm.app.userNotification"
    static let actionShowIdentifier = "com.cmuxterm.app.userNotification.show"
    private enum AuthorizationRequestOrigin {
        case notificationDelivery
        case settingsButton
        case settingsTest
    }

    @Published private(set) var notifications: [TerminalNotification] = [] {
        didSet {
            indexes = Self.buildIndexes(for: notifications)
            refreshDockBadge()
        }
    }
    @Published private(set) var authorizationState: NotificationAuthorizationState = .unknown

    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAutomaticAuthorization = false
    private var isAuthorizationRequestInFlight = false
    private var hasDeferredAuthorizationRequest = false
    private var hasPromptedForSettings = false
    private var userDefaultsObserver: NSObjectProtocol?
    private let settingsPromptWindowRetryDelay: TimeInterval = 0.5
    private let settingsPromptWindowRetryLimit = 20
    private var notificationSettingsWindowProvider: () -> NSWindow? = {
        NSApp.keyWindow ?? NSApp.mainWindow
    }
    private var notificationSettingsAlertFactory: () -> NSAlert = {
        NSAlert()
    }
    private var notificationSettingsScheduler: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void = {
        delay,
        block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            block()
        }
    }
    private var notificationSettingsURLOpener: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
    private var indexes = NotificationIndexes()

    private init() {
        indexes = Self.buildIndexes(for: notifications)
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDockBadge()
        }
        refreshDockBadge()
        refreshAuthorizationStatus()
    }

    deinit {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
    }

    static func dockBadgeLabel(unreadCount: Int, isEnabled: Bool, runTag: String? = nil) -> String? {
        let unreadLabel: String? = {
            guard isEnabled, unreadCount > 0 else { return nil }
            if unreadCount > 99 {
                return "99+"
            }
            return String(unreadCount)
        }()

        if let tag = TaggedRunBadgeSettings.normalizedTag(runTag) {
            if let unreadLabel {
                return "\(tag):\(unreadLabel)"
            }
            return tag
        }

        return unreadLabel
    }

    var unreadCount: Int {
        indexes.unreadCount
    }

    func refreshAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorizationFromSettings() {
        ensureAuthorization(origin: .settingsButton) { _ in }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        notificationSettingsURLOpener(url)
    }

    func sendSettingsTestNotification() {
        ensureAuthorization(origin: .settingsTest) { [weak self] authorized in
            guard let self, authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "cmux test notification"
            content.body = "Desktop notifications are enabled."
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier

            let request = UNNotificationRequest(
                identifier: "cmux.settings.test.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            self.center.add(request) { error in
                if let error {
                    NSLog("Failed to schedule test notification: \(error)")
                } else {
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body
                    )
                }
            }
        }
    }

    func handleApplicationDidBecomeActive() {
        if hasDeferredAuthorizationRequest {
            hasDeferredAuthorizationRequest = false
            ensureAuthorization(origin: .settingsButton) { _ in }
            return
        }
        refreshAuthorizationStatus()
    }

    func unreadCount(forTabId tabId: UUID) -> Int {
        indexes.unreadCountByTabId[tabId] ?? 0
    }

    func hasUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        indexes.unreadByTabSurface.contains(TabSurfaceKey(tabId: tabId, surfaceId: surfaceId))
    }

    func latestNotification(forTabId tabId: UUID) -> TerminalNotification? {
        indexes.latestUnreadByTabId[tabId] ?? indexes.latestByTabId[tabId]
    }

    func addNotification(tabId: UUID, surfaceId: UUID?, title: String, subtitle: String, body: String) {
        var updated = notifications
        var idsToClear: [String] = []
        updated.removeAll { existing in
            guard existing.tabId == tabId, existing.surfaceId == surfaceId else { return false }
            idsToClear.append(existing.id.uuidString)
            return true
        }

        let isActiveTab = AppDelegate.shared?.tabManager?.selectedTabId == tabId
        let focusedSurfaceId = AppDelegate.shared?.tabManager?.focusedSurfaceId(for: tabId)
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        let isFocusedPanel = isActiveTab && isFocusedSurface
        let isAppFocused = AppFocusState.isAppFocused()
        if isAppFocused && isFocusedPanel {
            if !idsToClear.isEmpty {
                notifications = updated
                center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
                center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
            }
            return
        }

        if WorkspaceAutoReorderSettings.isEnabled() {
            AppDelegate.shared?.tabManager?.moveTabToTop(tabId)
        }

        let notification = TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(),
            isRead: false
        )
        updated.insert(notification, at: 0)
        notifications = updated
        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
        scheduleUserNotification(notification)
    }

    func markRead(id: UUID) {
        var updated = notifications
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        guard !updated[index].isRead else { return }
        updated[index].isRead = true
        notifications = updated
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
    }

    func markRead(forTabId tabId: UUID) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId && !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markRead(forTabId tabId: UUID, surfaceId: UUID?) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId,
               updated[index].surfaceId == surfaceId,
               !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markUnread(forTabId tabId: UUID) {
        var updated = notifications
        var didChange = false
        for index in updated.indices {
            if updated[index].tabId == tabId, updated[index].isRead {
                updated[index].isRead = false
                didChange = true
            }
        }
        if didChange {
            notifications = updated
        }
    }

    func markAllRead() {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func remove(id: UUID) {
        var updated = notifications
        let originalCount = updated.count
        updated.removeAll { $0.id == id }
        guard updated.count != originalCount else { return }
        notifications = updated
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
    }

    func clearAll() {
        guard !notifications.isEmpty else { return }
        let ids = notifications.map { $0.id.uuidString }
        notifications.removeAll()
        center.removeDeliveredNotificationsOffMain(withIdentifiers: ids)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: ids)
    }

    func clearNotifications(forTabId tabId: UUID, surfaceId: UUID?) {
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId, notification.surfaceId == surfaceId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    func clearNotifications(forTabId tabId: UUID) {
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    private func scheduleUserNotification(_ notification: TerminalNotification) {
        ensureAuthorization(origin: .notificationDelivery) { [weak self] authorized in
            guard let self, authorized else { return }

            let content = UNMutableNotificationContent()
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "cmux"
            content.title = notification.title.isEmpty ? appName : notification.title
            content.subtitle = notification.subtitle
            content.body = notification.body
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = [
                "tabId": notification.tabId.uuidString,
                "notificationId": notification.id.uuidString,
            ]
            if let surfaceId = notification.surfaceId {
                content.userInfo["surfaceId"] = surfaceId.uuidString
            }

            let request = UNNotificationRequest(
                identifier: notification.id.uuidString,
                content: content,
                trigger: nil
            )

            self.center.add(request) { error in
                if let error {
                    NSLog("Failed to schedule notification: \(error)")
                } else {
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body
                    )
                }
            }
        }
    }

    private func ensureAuthorization(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool) -> Void
    ) {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }

                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    completion(true)
                case .denied:
                    self.promptToEnableNotifications()
                    completion(false)
                case .notDetermined:
                    if Self.shouldDeferAutomaticAuthorizationRequest(
                        origin: origin,
                        status: settings.authorizationStatus,
                        isAppActive: AppFocusState.isAppActive()
                    ) {
                        self.hasDeferredAuthorizationRequest = true
                        completion(false)
                    } else {
                        self.requestAuthorizationIfNeeded(origin: origin, completion)
                    }
                @unknown default:
                    completion(false)
                }
            }
        }
    }

    private func requestAuthorizationIfNeeded(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool) -> Void
    ) {
        let isAutomaticRequest = origin == .notificationDelivery
        guard Self.shouldRequestAuthorization(
            isAutomaticRequest: isAutomaticRequest,
            hasRequestedAutomaticAuthorization: hasRequestedAutomaticAuthorization,
            isAuthorizationRequestInFlight: isAuthorizationRequestInFlight
        ) else {
            completion(false)
            return
        }
        if isAutomaticRequest {
            hasRequestedAutomaticAuthorization = true
        }
        isAuthorizationRequestInFlight = true
        hasDeferredAuthorizationRequest = false
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                self.isAuthorizationRequestInFlight = false
                if granted {
                    self.authorizationState = .authorized
                } else {
                    self.refreshAuthorizationStatus()
                }
                completion(granted)
            }
        }
    }

    private func promptToEnableNotifications() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasPromptedForSettings else { return }
            self.hasPromptedForSettings = true
            self.presentNotificationSettingsPrompt(attempt: 0)
        }
    }

    private func presentNotificationSettingsPrompt(attempt: Int) {
        guard let window = notificationSettingsWindowProvider() else {
            guard attempt < settingsPromptWindowRetryLimit else {
                // If no window is available after retries, allow a future denied callback
                // to prompt again when the app has a key/main window.
                hasPromptedForSettings = false
                return
            }
            notificationSettingsScheduler(settingsPromptWindowRetryDelay) { [weak self] in
                self?.presentNotificationSettingsPrompt(attempt: attempt + 1)
            }
            return
        }

        let alert = notificationSettingsAlertFactory()
        alert.messageText = String(localized: "dialog.enableNotifications.title", defaultValue: "Enable Notifications for cmux")
        alert.informativeText = String(localized: "dialog.enableNotifications.message", defaultValue: "Notifications are disabled for cmux. Enable them in System Settings to see alerts.")
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.openSettings", defaultValue: "Open Settings"))
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.notNow", defaultValue: "Not Now"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.openNotificationSettings()
        }
    }

    static func authorizationState(from status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }

    static func shouldDeferAutomaticAuthorizationRequest(
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        status == .notDetermined && !isAppActive
    }

    static func shouldRequestAuthorization(
        isAutomaticRequest: Bool,
        hasRequestedAutomaticAuthorization: Bool,
        isAuthorizationRequestInFlight: Bool
    ) -> Bool {
        guard !isAuthorizationRequestInFlight else { return false }
        guard isAutomaticRequest else { return true }
        return !hasRequestedAutomaticAuthorization
    }

    private static func shouldDeferAutomaticAuthorizationRequest(
        origin: AuthorizationRequestOrigin,
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        guard origin == .notificationDelivery else { return false }
        return shouldDeferAutomaticAuthorizationRequest(status: status, isAppActive: isAppActive)
    }

    private static func buildIndexes(for notifications: [TerminalNotification]) -> NotificationIndexes {
        var indexes = NotificationIndexes()
        for notification in notifications {
            if indexes.latestByTabId[notification.tabId] == nil {
                indexes.latestByTabId[notification.tabId] = notification
            }
            guard !notification.isRead else { continue }
            indexes.unreadCount += 1
            indexes.unreadCountByTabId[notification.tabId, default: 0] += 1
            indexes.unreadByTabSurface.insert(
                TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
            )
            if indexes.latestUnreadByTabId[notification.tabId] == nil {
                indexes.latestUnreadByTabId[notification.tabId] = notification
            }
        }
        return indexes
    }

#if DEBUG
    func configureNotificationSettingsPromptHooksForTesting(
        windowProvider: @escaping () -> NSWindow?,
        alertFactory: @escaping () -> NSAlert,
        scheduler: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void,
        urlOpener: @escaping (URL) -> Void
    ) {
        notificationSettingsWindowProvider = windowProvider
        notificationSettingsAlertFactory = alertFactory
        notificationSettingsScheduler = scheduler
        notificationSettingsURLOpener = urlOpener
        hasPromptedForSettings = false
    }

    func resetNotificationSettingsPromptHooksForTesting() {
        notificationSettingsWindowProvider = { NSApp.keyWindow ?? NSApp.mainWindow }
        notificationSettingsAlertFactory = { NSAlert() }
        notificationSettingsScheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                block()
            }
        }
        notificationSettingsURLOpener = { url in
            NSWorkspace.shared.open(url)
        }
        hasPromptedForSettings = false
    }

    func promptToEnableNotificationsForTesting() {
        promptToEnableNotifications()
    }

    func replaceNotificationsForTesting(_ notifications: [TerminalNotification]) {
        self.notifications = notifications
    }
#endif

    private func refreshDockBadge() {
        let label = Self.dockBadgeLabel(
            unreadCount: unreadCount,
            isEnabled: NotificationBadgeSettings.isDockBadgeEnabled(),
            runTag: TaggedRunBadgeSettings.normalizedTag()
        )
        NSApp?.dockTile.badgeLabel = label
    }
}
