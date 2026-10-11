import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// A page's web notification (`BrowserTabIntent.webNotification`): a daemon
/// notification on the page's tab, as `cmux notify` posts one, so it marks
/// the tab unread and follows the notification settings. The banner's body
/// starts with the page's site. A click focuses the tab (`open(surface:)`)
/// and runs the page's click handler.
extension NotificationCenterService {
    func postWebNotification(_ notification: BrowserWebNotification, surface: SurfaceID) {
        guard let services else { return }
        let title = notification.title
        let body = notification.body.isEmpty ? notification.site : "\(notification.site)\n\(notification.body)"
        let (clicks, click) = (webNotificationClicks, notification.click)
        services.daemon.send("web notification") { connection in
            let id = try await connection.notify(title: title, body: body, surface: surface, source: NotificationSource.cli.rawValue)
            await clicks.add(id, click)
        }
    }
}

/// The click handlers of the last web notifications, by banner id.
@MainActor
final class WebNotificationClicks {
    private var handlers: [String: @MainActor () -> Void] = [:]
    private var order: [String] = []
    private static let limit = 32

    func add(_ id: NotificationID, _ click: @escaping @MainActor () -> Void) {
        let banner = "cmux-notification-\(id.rawValue)"
        handlers[banner] = click
        order.append(banner)
        if order.count > Self.limit { handlers[order.removeFirst()] = nil }
    }

    /// Runs the page's handler of banner `bannerID`, if it was a web notification.
    func run(bannerID: String) {
        handlers[bannerID]?()
    }
}
