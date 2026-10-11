import Foundation

extension Strings {
    /// One tooltip line: `Claude Code · Editing app.rs:42`.
    static func presenceLine(_ presence: SidebarPresence) -> String {
        let doing = presence.target.map { "\(presenceActivity(presence.activity)) \($0)" } ?? presenceActivity(presence.activity)
        return "\(presence.name) · \(doing)"
    }

    static func presenceActivity(_ activity: SidebarPresence.Activity) -> String {
        switch activity {
        case .thinking: String(localized: "sidebar.presence.thinking", defaultValue: "Thinking", bundle: .module)
        case .editing: String(localized: "sidebar.presence.editing", defaultValue: "Editing", bundle: .module)
        case .reading: String(localized: "sidebar.presence.reading", defaultValue: "Reading", bundle: .module)
        case .running: String(localized: "sidebar.presence.running", defaultValue: "Running a command", bundle: .module)
        case .browsing: String(localized: "sidebar.presence.browsing", defaultValue: "Using the browser", bundle: .module)
        case .computerUse: String(localized: "sidebar.presence.computerUse", defaultValue: "Using the computer", bundle: .module)
        case .waiting: String(localized: "sidebar.presence.waiting", defaultValue: "Waiting for you", bundle: .module)
        }
    }
}
