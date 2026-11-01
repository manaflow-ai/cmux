import Foundation

/// What a banner from an incognito window says (leo-workspace design/spaces.md "Incognito": nothing of the
/// window is kept; spaces-incognito-audit leak 5). Notification Center keeps every banner in its history, so
/// this one names nothing of the window: no workspace, tab, machine, agent state or message, and no status
/// badge or Allow/Deny of an agent's request. A click still opens the tab, in its incognito window.
extension DesktopNotifier {
    static var incognitoTitle: String {
        String(localized: "notifications.incognito.title", defaultValue: "Incognito", table: "NotificationsPanel", bundle: .module)
    }

    static var incognitoBody: String {
        String(localized: "notifications.incognito.body", defaultValue: "A tab in an incognito window needs you.",
               table: "NotificationsPanel", bundle: .module)
    }
}
