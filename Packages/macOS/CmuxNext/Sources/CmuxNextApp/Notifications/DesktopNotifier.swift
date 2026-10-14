import AppKit
import CmuxNextDesign
import CmuxNextMobileHost
import os
import UserNotifications

/// macOS notification banners through `UNUserNotificationCenter`, so the
/// user's notification settings and Focus modes apply (macOS filters the
/// banner and its default sound). A banner click opens the notifying tab
/// through `onOpen`; a reply banner's typed text goes to `onReply`. The center is touched only when the first banner posts,
/// so hosts without a bundle identifier (tests) never create it. An
/// automation launch (`WindowDrawPolicy.isAutomationLaunch`: e2e scripts and
/// GUI proofs on shared hosts) never creates it either: no authorization
/// request and no system banner cover the host's screen; `posted` still
/// records each banner for `debug.notifications`.
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
    }

    /// Banner clicked: the notification id and its tab's surface handle.
    var onOpen: ((_ id: String, _ surface: UInt64?) -> Void)?
    /// A reply banner's text sent: the notification id, its tab's surface handle and the text.
    var onReply: ((_ id: String, _ surface: UInt64?, _ text: String) -> Void)?
    /// The category of banners with a Reply field, and its action.
    nonisolated static let replyCategory = "cmux.notification.reply"
    nonisolated static let replyAction = "cmux.notification.reply.send"
    /// The last banners asked for, newest last (bounded).
    private(set) var posted: [Posted] = []
    /// Whether this launch uses the system notification center (not in automation launches).
    nonisolated static let usesSystemCenter = !WindowDrawPolicy.isAutomationLaunch(ProcessInfo.processInfo.environment)
    /// Authorization as the center last reported it ("authorized", "denied", ...);
    /// "automation" when this launch never asks.
    private(set) var authorization = DesktopNotifier.usesSystemCenter ? "unknown" : "automation"
    private var center: UNUserNotificationCenter?
    private var requestedAuthorization = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "notifications")
    private static let postedLimit = 32

    /// Posts a banner. `sound == "default"` uses the notification's own
    /// sound (Focus and the per-app sound setting apply); other sounds are
    /// played by `NotificationSounds`. `attachment` is a status badge PNG
    /// (OSC 7501 alerts), written to a file only for a banner the center
    /// will take (it moves the file); a failed one is deleted.
    func post(id: String, title: String, subtitle: String? = nil, body: String, surface: UInt64?, workspace: String?,
              defaultSound: Bool, attachment: Data? = nil, reply: Bool = false, category: String? = nil) {
        posted.append(Posted(id: id, title: title, subtitle: subtitle, body: body, surface: surface,
                             sound: defaultSound ? "default" : nil, attachment: attachment, reply: reply))
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
        if let category = category ?? (reply ? Self.replyCategory : nil) { content.categoryIdentifier = category }
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

    /// Removes delivered banners whose notifications were read.
    func withdraw(_ ids: [String]) {
        guard !ids.isEmpty, let center else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// The banner click path, also used by `debug.notifications` (click).
    func open(id: String, surface: UInt64?) {
        onOpen?(id, surface)
    }

    /// The Reply field's Send path, also used by `debug.notifications` (reply).
    func reply(id: String, surface: UInt64?, text: String) {
        onReply?(id, surface, text)
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

    private func resolvedCenter() -> UNUserNotificationCenter? {
        if let center { return center }
        guard Self.usesSystemCenter, Self.isMainAppBundle(bundleIdentifier: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL) else {
            return nil
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.replyBannerCategory(), IPhonePairNotices.notificationCategory()])
        self.center = center
        if !requestedAuthorization {
            requestedAuthorization = true
            center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
                Task { @MainActor in self?.authorization = granted ? "authorized" : "denied" }
            }
        }
        return center
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
        return UNNotificationCategory(identifier: replyCategory, actions: [action], intentIdentifiers: [])
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
        let isDefault = [UNNotificationDefaultActionIdentifier, IPhonePairNotices.reviewAction].contains(response.actionIdentifier)
        let replied = response.actionIdentifier == Self.replyAction ? (response as? UNTextInputNotificationResponse)?.userText : nil
        Task { @MainActor [weak self] in
            if isDefault { self?.open(id: id, surface: surface) }
            if let replied { self?.reply(id: id, surface: surface, text: replied) }
        }
        completionHandler()
    }
}

/// Sounds other than the notification's default: a system sound by name
/// (`/System/Library/Sounds`, for example "Glass") or a file path.
enum NotificationSounds {
    @MainActor
    static func play(_ name: String) {
        guard name != "none", name != "default" else { return }
        let sound = name.hasPrefix("/") ? NSSound(contentsOfFile: name, byReference: true) : NSSound(named: NSSound.Name(name))
        sound?.play()
    }

    /// A poster asked for no banner (`notify --desktop false`): the
    /// notification's own default sound has no banner to ride, so the
    /// system alert sound stands in, as classic played one.
    @MainActor
    static func playWithoutBanner(_ name: String) {
        name == "default" ? NSSound.beep() : play(name)
    }
}
