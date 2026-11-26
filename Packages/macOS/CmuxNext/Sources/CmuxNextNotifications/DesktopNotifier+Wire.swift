import CmuxNextDesign
import CmuxNextWindowRules

/// What cmux-window-rules `desktop_center` answers (`window_notifications_desktop_launch`, `_banner`,
/// `_response`): how this launch uses Notification Center, a banner's category and redaction, and what a
/// click on a banner's action does. No rule lives here; a rule that does not answer falls back to the
/// launch, banner or click doing the least (no opt-ins, no prompt's buttons, only the system's own open).
extension DesktopNotifier {
    nonisolated struct Launch: Decodable {
        var usesSystemCenter: Bool
        var asksPermission: Bool
        var startsWithoutDeliveredBanners: Bool
    }

    nonisolated struct BannerShape: Decodable {
        var category: String
        var approval: Bool
        var redacted: Bool
    }

    nonisolated struct Click: Decodable, Sendable {
        var open: Bool
        var reply: Bool
        var approve: Bool?
        var always: Bool
        var markRead: Bool
    }

    nonisolated struct LaunchAsk: Encodable {
        var environment: [String: String]
        var automation: Bool
    }

    nonisolated struct BannerAsk: Encodable {
        var approval: Bool
        var alwaysAllow: Bool
        var reply: Bool
        var incognito: Bool
        var category: String?
    }

    nonisolated struct ActionAsk: Encodable {
        var action: String
        var systemDefault: Bool
    }

    /// How a launch with `environment` uses the system notification center.
    nonisolated static func launch(_ environment: [String: String]) -> Launch {
        let automation = WindowDrawPolicy.isAutomationLaunch(environment)
        return WindowRules().call("window_notifications_desktop_launch", LaunchAsk(environment: environment, automation: automation),
                                  as: Launch.self)
            ?? Launch(usesSystemCenter: !automation, asksPermission: !automation, startsWithoutDeliveredBanners: false)
    }

    /// A banner's category (the poster's own, else a prompt's, a reply banner's or the default) and whether
    /// it names nothing of its window.
    nonisolated static func shape(approval: Bool, alwaysAllow: Bool, reply: Bool, incognito: Bool, category: String?) -> BannerShape {
        let request = BannerAsk(approval: approval, alwaysAllow: alwaysAllow, reply: reply, incognito: incognito, category: category)
        return WindowRules().call("window_notifications_desktop_banner", request, as: BannerShape.self)
            ?? BannerShape(category: category ?? (reply ? replyCategory : defaultCategory), approval: false, redacted: incognito)
    }

    /// What a click on banner action `identifier` does; `systemDefault`: the banner itself was clicked.
    nonisolated static func action(_ identifier: String, systemDefault: Bool) -> Click {
        WindowRules().call("window_notifications_desktop_response", ActionAsk(action: identifier, systemDefault: systemDefault),
                           as: Click.self)
            ?? Click(open: systemDefault, reply: false, approve: nil, always: false, markRead: false)
    }
}
