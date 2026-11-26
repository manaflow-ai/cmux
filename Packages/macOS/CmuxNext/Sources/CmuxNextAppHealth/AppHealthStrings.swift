import Foundation

/// The names the app gives the parts it registers with app health's Rust model. They are never drawn: the model
/// repairs a part by itself and writes what it did to the log (Leo, 2026-11-22, ask-a78f915862: "the fuck is
/// actionable about "needs a repair". if it's unactionable, get rid of it."), so there is no line, card or toast
/// for a part that is stuck, repairing or out of repairs.
struct AppHealthStrings {
    static var sessionDaemon: String { String(localized: "appHealth.part.sessionDaemon", defaultValue: "Session service", table: "AppHealth", bundle: .localizedModule) }
    static var connection: String {
        String(localized: "appHealth.part.acpmux", defaultValue: "Connection to the session service", table: "AppHealth", bundle: .localizedModule)
    }
    static var pageHost: String { String(localized: "appHealth.part.pageHost", defaultValue: "Page server", table: "AppHealth", bundle: .localizedModule) }

    /// The page parts' names in plain words: a page's own name is its resource ("agent-pane"), which reads as
    /// code ("Agent pane"); the agent chat is what the person calls it.
    static func pageLabel(resource: String, fallback: String) -> String {
        switch resource {
        case "agent-pane":
            String(localized: "appHealth.part.agentChat", defaultValue: "Agent chat", table: "AppHealth", bundle: .localizedModule)
        default: fallback
        }
    }
}
