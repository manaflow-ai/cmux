import Foundation

extension Strings {
    /// One tooltip line: `Claude Code · Editing app.rs:42`.
    static func presenceLine(_ presence: SidebarPresence) -> String {
        let activity = presenceActivity(presence.activity)
        let doing = presence.target.map { target in
            String(localized: "sidebar.presence.activityTarget", defaultValue: "\(activity) \(target)", bundle: .module)
        } ?? activity
        return String(localized: "sidebar.presence.line", defaultValue: "\(presence.name) · \(doing)", bundle: .module)
    }

    /// The dots' overflow count: `+2`.
    static func presenceOverflow(_ count: Int) -> String {
        String(localized: "sidebar.presence.overflow", defaultValue: "+\(count)", bundle: .module)
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

extension SidebarPresence {
    /// Who is doing what, localized: `Claude Code · Editing app.rs:42`.
    public var summary: String { Strings.presenceLine(self) }
}
