import AppKit
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextDesign
import CmuxNextMobileHost
import os
import UserNotifications

/// macOS notification banners through `UNUserNotificationCenter`, so the
/// user's notification settings and Focus modes apply (macOS filters the
/// banner and its default sound). A banner click opens the notifying tab
/// through `onOpen`; a reply banner's typed text goes to `onReply`. The center is touched only when the first banner posts
/// (which asks for authorization) or `notifications.status` / `notifications.request` reads or asks for it
/// (`permission()`, for `cmux setup notifications`), so hosts without a bundle identifier (tests) never
/// create it. An automation launch (`WindowDrawPolicy.isAutomationLaunch`: e2e scripts and
/// GUI proofs on shared hosts) never creates it either: no authorization
/// request and no system banner cover the host's screen, and the two methods answer `unavailable`;
/// `posted` still records each banner for `debug.notifications`. An automation launch with
/// `CMUX_NEXT_NATIVE_NOTIFICATIONS=1` (a capture that holds the whole host, so a real banner
/// can be shown and shot) uses the system center as a user's launch does; its socket stays in
/// automation mode.
@MainActor
final class DesktopNotifier: NSObject {
    /// A banner the app asked for (for `debug.notifications`).
    struct Posted: Hashable {
        var id: String
        var title: String
        /// The workspace a terminal program's banner came from, else nil.
        var subtitle: String?
        var body: String
        var surface: UInt64?
        var sound: String?
        /// The status badge PNG the banner carries (OSC 7501 alerts), else nil.
        var attachment: Data?
        /// The banner takes a typed reply (`notify --reply`).
        var reply = false
        /// The banner answers an agent chat's permission prompt (Allow once, Deny).
        var approval = false
        /// The banner's action set (`defaultCategory`, `replyCategory`, the approval one, ...).
        var category: String?
    }

    /// Banner clicked: the notification id and its tab's surface handle.
    var onOpen: ((_ id: String, _ surface: UInt64?) -> Void)?
    /// A reply banner's text sent: the notification id, its tab's surface handle and the text.
    var onReply: ((_ id: String, _ surface: UInt64?, _ text: String) -> Void)?
    /// An approval banner's Allow once (true) or Deny (false): the notification id, its tab's surface handle.
    var onApprove: ((_ id: String, _ surface: UInt64?, _ allow: Bool) -> Void)?
    /// Mark as Read: the notification id and its tab's surface handle; the tab is read, not opened.
    var onMarkRead: ((_ id: String, _ surface: UInt64?) -> Void)?
    /// The category of banners with a Reply field, and its action.
    nonisolated static let replyCategory = "cmux.notification.reply"
    nonisolated static let replyAction = "cmux.notification.reply.send"
    /// Every other app banner's category: Open and Mark as Read.
    nonisolated static let defaultCategory = "cmux.notification.default"
    nonisolated static let openAction = "cmux.notification.open"
    nonisolated static let markReadAction = "cmux.notification.markRead"
    /// The last banners asked for, newest last (bounded).
    private(set) var posted: [Posted] = []
    /// Whether this launch uses the system notification center (not in automation launches,
    /// unless they opt in with `CMUX_NEXT_NATIVE_NOTIFICATIONS=1`).
    nonisolated static let usesSystemCenter = usesSystemCenter(in: ProcessInfo.processInfo.environment)
    /// The launch variable an automation launch sets to post real system banners.
    nonisolated static let nativeNotificationsVariable = "CMUX_NEXT_NATIVE_NOTIFICATIONS"

    /// Whether a launch with `environment` uses the system notification center: every launch but
    /// an automation one, and an automation one that sets `CMUX_NEXT_NATIVE_NOTIFICATIONS=1`.
    nonisolated static func usesSystemCenter(in environment: [String: String]) -> Bool {
        optsIntoNativeNotifications(environment) || !WindowDrawPolicy.isAutomationLaunch(environment)
    }

    /// Whether a launch with `environment` asks macOS for notification permission and answers
    /// `notifications.status` / `notifications.request`: one that uses the system center, unless it is a
    /// GUI job (`NX_REMOTE=1`, `CMUX_TEST_REQUIRE_GUI=1`: the banner would catch its clicks) that did not
    /// opt in with `CMUX_NEXT_NATIVE_NOTIFICATIONS=1`.
    nonisolated static func asksPermission(in environment: [String: String]) -> Bool {
        usesSystemCenter(in: environment) && (optsIntoNativeNotifications(environment) || !isGUIJob(environment))
    }

    /// An automation launch that opted in to the system center (`CMUX_NEXT_NATIVE_NOTIFICATIONS=1`): it starts
    /// with this bundle's delivered notifications removed (`startsWithoutDeliveredBanners(in:)`).
    nonisolated static let startsWithoutDeliveredBanners = startsWithoutDeliveredBanners(in: ProcessInfo.processInfo.environment)

    /// Whether a launch with `environment` removes this bundle's delivered notifications when it first uses the
    /// system center: only an automation launch that opted in, never a user's launch.
    nonisolated static func startsWithoutDeliveredBanners(in environment: [String: String]) -> Bool {
        optsIntoNativeNotifications(environment) && WindowDrawPolicy.isAutomationLaunch(environment)
    }

    nonisolated private static func optsIntoNativeNotifications(_ environment: [String: String]) -> Bool {
        environment[nativeNotificationsVariable] == "1"
    }
    /// Authorization as the center last reported it ("authorized", "denied", ...);
    /// "automation" when this launch never asks.
    private(set) var authorization = DesktopNotifier.usesSystemCenter ? "unknown" : "automation"
    private var center: UNUserNotificationCenter?
    /// Whether this launch asked for authorization (a banner or `notifications.request`).
    private var askedAuthorization = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "notifications")
    private static let postedLimit = 32

    /// Posts a banner. `sound == "default"` uses the notification's own
    /// sound (Focus and the per-app sound setting apply); other sounds are
    /// played by `NotificationSoundPlayer`. `attachment` is a status badge PNG
    /// (OSC 7501 alerts), written to a file only for a banner the center
    /// will take (it moves the file); a failed one is deleted.
    func post(id: String, title: String, subtitle: String? = nil, body: String, surface: UInt64?, workspace: String?,
              defaultSound: Bool, attachment: Data? = nil, reply: Bool = false, approval: Bool = false, category: String? = nil) {
        let category = category ?? (approval ? AgentApprovalBanners.category : reply ? Self.replyCategory : Self.defaultCategory)
        posted.append(Posted(id: id, title: title, subtitle: subtitle, body: body, surface: surface,
                             sound: defaultSound ? "default" : nil, attachment: attachment, reply: reply,
                             approval: approval, category: category))
        if posted.count > Self.postedLimit { posted.removeFirst(posted.count - Self.postedLimit) }
        guard let center = resolvedCenter() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        let attachmentFile: URL? = attachment.flatMap { Self.writeAttachment($0, id: id) }.flatMap { file in
            guard let item = try? UNNotificationAttachment(identifier: "status", url: file) else {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            content.attachments = [item]
            return file
        }
        content.sound = defaultSound ? .default : nil
        content.interruptionLevel = .active
        if let workspace { content.threadIdentifier = workspace }
        content.categoryIdentifier = category
        var info: [String: Any] = ["notification": id]
        if let surface { info["surface"] = NSNumber(value: surface) }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let logger = logger
        center.add(request) { error in
            guard let error else { return }
            logger.error("banner failed: \(String(describing: error), privacy: .public)")
            if let attachmentFile { try? FileManager.default.removeItem(at: attachmentFile) }
        }
    }

    /// A file for one banner's attachment in the temporary directory.
    private static func writeAttachment(_ data: Data, id: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cmux-status-notifications", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(id)-\(UUID().uuidString).png")
        do {
            try data.write(to: file)
            return file
        } catch {
            return nil
        }
    }

    /// Whether banner `id` is in Notification Center (an automation launch has none).
    func isDelivered(_ id: String) async -> Bool {
        guard let center = configuredCenter() else { return posted.contains { $0.id == id } }
        return await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { delivered in continuation.resume(returning: delivered.contains { $0.request.identifier == id }) }
        }
    }

    /// Removes banners whose notifications were read or ended, shown or still queued.
    func withdraw(_ ids: [String]) {
        guard !ids.isEmpty, let center else { return }
        for remove in [center.removeDeliveredNotifications(withIdentifiers:), center.removePendingNotificationRequests(withIdentifiers:)] { remove(ids) }
    }

    /// The banner click path, also used by `debug.notifications` (click).
    func open(id: String, surface: UInt64?) {
        onOpen?(id, surface)
    }

    /// The Reply field's Send path, also used by `debug.notifications` (reply).
    func reply(id: String, surface: UInt64?, text: String) {
        onReply?(id, surface, text)
    }

    /// Mark as Read, also used by `debug.notifications` (mark_read).
    func markRead(id: String, surface: UInt64?) {
        onMarkRead?(id, surface)
    }

    /// An approval banner's Allow once or Deny, also used by `debug.notifications` (allow, deny).
    func approve(id: String, surface: UInt64?, allow: Bool) {
        onApprove?(id, surface, allow)
    }

    /// CEF embeds the same executable in helper app bundles whose identifiers
    /// contain a `.helper.*` component. Only the main cmux app may own the
    /// macOS notification center and request authorization.
    nonisolated static func isMainAppBundle(bundleIdentifier: String?, bundleURL: URL) -> Bool {
        let root = "com.cmuxterm.app"
        guard let bundleIdentifier,
              (bundleIdentifier == root || bundleIdentifier.hasPrefix(root + ".")),
              !bundleIdentifier.split(separator: ".").contains("helper"),
              bundleURL.pathExtension == "app" else { return false }
        return true
    }

    /// The center for a banner: the first one asks for authorization.
    private func resolvedCenter() -> UNUserNotificationCenter? {
        guard let center = configuredCenter() else { return nil }
        // Asked once; a GUI job (NX_REMOTE=1, CMUX_TEST_REQUIRE_GUI=1) never asks: the banner catches its clicks.
        if !askedAuthorization, Self.asksPermission {
            askedAuthorization = true
            center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
                Task { @MainActor in self?.authorization = granted ? "authorized" : "denied" }
            }
        }
        return center
    }

    /// The system center with this app's delegate and banner categories, made once; nil when
    /// this launch never uses it (an automation launch, or not the main app bundle).
    private func configuredCenter() -> UNUserNotificationCenter? {
        if let center { return center }
        guard Self.usesSystemCenter, Self.isMainAppBundle(bundleIdentifier: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL) else {
            return nil
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if Self.startsWithoutDeliveredBanners {
            // An automation launch starts from empty state, so its notification ids count from 1 again: a banner a
            // previous launch left in Notification Center under the same id would turn the next post into a silent
            // update. Only this launch's own notifications are removed (they are all stale).
            center.removeAllDeliveredNotifications()
            center.removeAllPendingNotificationRequests()
        }
        center.setNotificationCategories([Self.defaultBannerCategory(), Self.replyBannerCategory(), AgentApprovalBanners.notificationCategory(),
                                          IPhonePairNotices.notificationCategory()])
        self.center = center
        return center
    }

    nonisolated private static func isGUIJob(_ environment: [String: String]) -> Bool {
        ["NX_REMOTE", "CMUX_TEST_REQUIRE_GUI"].contains { environment[$0] == "1" }
    }

    nonisolated private static var asksPermission: Bool { asksPermission(in: ProcessInfo.processInfo.environment) }

    /// The permission `notifications.status` reads and `notifications.request` asks for, on the
    /// banners' own center. A launch that never asks (an automation launch, a GUI job, not the
    /// main app bundle) answers `unavailable`.
    func permission() throws -> any NotificationPermissionCenter {
        guard Self.asksPermission, configuredCenter() != nil else {
            throw ControlError(code: "unavailable", message: NotificationPermissionStrings.unavailable)
        }
        return SystemNotificationPermission(bundleID: Bundle.main.bundleIdentifier) { [weak self] granted in
            Task { @MainActor in
                self?.askedAuthorization = true
                self?.authorization = granted ? "authorized" : "denied"
            }
        }
    }

    /// Reply banners' category: one text field whose Send types into the terminal.
    private static func replyBannerCategory() -> UNNotificationCategory {
        let action = UNTextInputNotificationAction(
            identifier: replyAction,
            title: String(localized: "notifications.reply.action", defaultValue: "Reply", bundle: .module),
            // A reply ends in Return in a terminal: the Mac must be unlocked to send one.
            options: [.authenticationRequired],
            textInputButtonTitle: String(localized: "notifications.reply.send", defaultValue: "Send", bundle: .module),
            textInputPlaceholder: String(localized: "notifications.reply.placeholder", defaultValue: "Reply to the terminal…", bundle: .module)
        )
        return UNNotificationCategory(identifier: replyCategory, actions: [action, markReadBannerAction()], intentIdentifiers: [])
    }

    /// Other banners' category: Open (brings cmux to the tab) and Mark as Read (reads it in place).
    private static func defaultBannerCategory() -> UNNotificationCategory {
        let open = UNNotificationAction(identifier: openAction,
                                        title: String(localized: "notifications.action.open", defaultValue: "Open", bundle: .module),
                                        options: [.foreground])
        return UNNotificationCategory(identifier: defaultCategory, actions: [open, markReadBannerAction()], intentIdentifiers: [])
    }

    /// Mark as Read: reads the banner's tab without bringing cmux forward.
    private static func markReadBannerAction() -> UNNotificationAction {
        UNNotificationAction(identifier: markReadAction,
                             title: String(localized: "notifications.action.markRead", defaultValue: "Mark as Read", bundle: .module))
    }
}

extension DesktopNotifier: UNUserNotificationCenterDelegate {
    /// The app decided to post it: show it even while cmux is active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = info["notification"] as? String ?? response.notification.request.identifier
        let surface = (info["surface"] as? NSNumber)?.uint64Value
        let isDefault = [UNNotificationDefaultActionIdentifier, IPhonePairNotices.reviewAction, Self.openAction].contains(response.actionIdentifier)
        let markRead = response.actionIdentifier == Self.markReadAction
        let replied = response.actionIdentifier == Self.replyAction ? (response as? UNTextInputNotificationResponse)?.userText : nil
        let approved = AgentApprovalBanners.decision(response.actionIdentifier)
        Task { @MainActor [weak self] in
            if isDefault { self?.open(id: id, surface: surface) }
            if let replied { self?.reply(id: id, surface: surface, text: replied) }
            if let approved { self?.approve(id: id, surface: surface, allow: approved) }
            if markRead { self?.markRead(id: id, surface: surface) }
        }
        completionHandler()
    }
}
