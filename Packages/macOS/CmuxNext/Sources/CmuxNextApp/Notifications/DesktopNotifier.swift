import AppKit
import os
import UserNotifications

/// macOS notification banners through `UNUserNotificationCenter`, so the
/// user's notification settings and Focus modes apply (macOS filters the
/// banner and its default sound). A banner click opens the notifying tab
/// through `onOpen`. The center is touched only when the first banner posts,
/// so hosts without a bundle identifier (tests) never create it.
@MainActor
final class DesktopNotifier: NSObject {
    /// A banner the app asked for (for `debug.notifications`).
    struct Posted: Hashable {
        var id: String
        var title: String
        var subtitle: String?
        var body: String
        var surface: UInt64?
        var sound: String?
    }

    /// Banner clicked: the notification id and its tab's surface handle.
    var onOpen: ((_ id: String, _ surface: UInt64?) -> Void)?
    /// The last banners asked for, newest last (bounded).
    private(set) var posted: [Posted] = []
    /// Authorization as the center last reported it ("authorized", "denied", ...).
    private(set) var authorization = "unknown"
    private var center: UNUserNotificationCenter?
    private var requestedAuthorization = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "notifications")
    private static let postedLimit = 32

    /// Posts a banner. `sound == "default"` uses the notification's own
    /// sound (Focus and the per-app sound setting apply); other sounds are
    /// played by `NotificationSounds`.
    /// `subtitle` is a status reason line and `attachment` a badge image
    /// file (OSC 7501 notifications); the center takes the file.
    func post(id: String, title: String, subtitle: String? = nil, body: String, surface: UInt64?, workspace: String?,
              defaultSound: Bool, attachment: URL? = nil) {
        posted.append(Posted(id: id, title: title, subtitle: subtitle, body: body, surface: surface,
                             sound: defaultSound ? "default" : nil))
        if posted.count > Self.postedLimit { posted.removeFirst(posted.count - Self.postedLimit) }
        guard let center = resolvedCenter() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        if let attachment, let item = try? UNNotificationAttachment(identifier: "status", url: attachment) {
            content.attachments = [item]
        }
        content.sound = defaultSound ? .default : nil
        content.interruptionLevel = .active
        if let workspace { content.threadIdentifier = workspace }
        var info: [String: Any] = ["notification": id]
        if let surface { info["surface"] = NSNumber(value: surface) }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let logger = logger
        center.add(request) { error in
            if let error { logger.error("banner failed: \(String(describing: error), privacy: .public)") }
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
        guard Self.isMainAppBundle(bundleIdentifier: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL) else {
            return nil
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        self.center = center
        if !requestedAuthorization {
            requestedAuthorization = true
            center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
                Task { @MainActor in self?.authorization = granted ? "authorized" : "denied" }
            }
        }
        return center
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
        let isDefault = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor [weak self] in
            if isDefault { self?.open(id: id, surface: surface) }
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
}
