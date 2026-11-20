package import CmuxNextControl
package import CmuxNextSettings
import Foundation

/// `notifications.banners`: the banners this app asked for, newest last (the bounded
/// `DesktopNotifier.posted`), as `{banners: [{id, title, subtitle, body, surface, reply, approval,
/// category}], authorization}`. A read: it moves no focus. An incognito window's banner is listed as
/// it showed, naming nothing of the window, its surface included (`DesktopNotifier.post`).
///
/// `notifications.open {"id": <banner id>}`: shows a tab banner's own surface, as its click does
/// (`DesktopNotifier.openTab`), never one the caller names, and answers `{opened, surface}`; an id no
/// listed banner has is `not_found` and runs nothing. Only a daemon notification's banner opens: any
/// other (passkey, iPhone pairing, attention, Runs) acts on the person's own click and is
/// `person_required`, and a web page's banner runs none of the page's click handler. It is an
/// explicit focus-intent command (skills/cmux-socket-policy): it shows the tab and moves in-app focus there.
///
/// Both are served by release builds (not `debug.*`), so a probe can check a Nightly from outside:
/// one banner per agent turn, and its click opens the chat (`cmux notification banners|open`).
/// Neither is in a remote relay allowlist: the banners are this Mac's own, and the open moves its focus.
extension ControlMethod {
    /// The two methods over `notifier`, read on the main actor for each call (nil: the app is closing).
    package static func notificationBanners(_ notifier: @escaping @MainActor @Sendable () -> DesktopNotifier?) -> [ControlMethod] {
        [
            .mainActor("notifications.banners") { _ in
                guard let notifier = notifier() else { return .value(.null) }
                return .value([
                    "banners": .array(notifier.posted.map(\.controlJSON)),
                    "authorization": .string(notifier.authorization),
                ])
            },
            .mainActor("notifications.open") { call in
                guard let id = call.params["id"]?.stringValue, !id.isEmpty else {
                    throw ControlError(code: "invalid_params", message: String(localized: "notifications.control.openNeedsID",
                        defaultValue: "params.id names the banner to open (an id notifications.banners lists)",
                        table: "NotificationsPanel", bundle: .module))
                }
                guard let notifier = notifier() else { return .value(.null) }
                // The newest banner with that id: a repeated id is the same tab's later banner.
                guard let banner = notifier.posted.last(where: { $0.id == id }) else {
                    let message = String(format: String(localized: "notifications.control.bannerNotFound",
                        defaultValue: "No banner %@: notifications.banners lists the banners this app asked for",
                        table: "NotificationsPanel", bundle: .module), id)
                    throw ControlError(code: "not_found", message: message, data: ["id": .string(id)])
                }
                // A passkey, pairing, attention or Run banner's click acts on the person's intent (a passkey's
                // starts a WebAuthn ceremony: agent-browser-passkey-DESIGN.md), so a script opens only a tab's.
                guard banner.id.hasPrefix(DesktopNotifier.tabBannerPrefix) else {
                    let message = String(format: String(localized: "notifications.control.openPersonOnly",
                        defaultValue: "Banner %@ opens only on your click in macOS; notifications.open opens a tab's banner",
                        table: "NotificationsPanel", bundle: .module), id)
                    throw ControlError(code: "person_required", message: message, data: ["id": .string(id)])
                }
                notifier.openTab(id: banner.id, surface: banner.surface)
                return .value(["opened": .string(banner.id), "surface": banner.listedSurface])
            },
        ]
    }
}

extension DesktopNotifier.Posted {
    /// The banner as `notifications.banners` and `debug.notifications` list it (the debug method adds
    /// its status badge PNG).
    package var controlJSON: JSONValue {
        [
            "id": .string(id), "title": .string(title),
            "subtitle": subtitle.map(JSONValue.string) ?? .null, "body": .string(body),
            "surface": listedSurface,
            "reply": .bool(reply), "approval": .bool(approval),
            "category": category.map(JSONValue.string) ?? .null,
        ]
    }

    /// The banner's surface as the lists show it: none for an incognito window's banner.
    var listedSurface: JSONValue {
        incognito ? .null : surface.map { .number(Double($0)) } ?? .null
    }
}
