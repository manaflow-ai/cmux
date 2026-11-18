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

    /// The drive indicator's tooltip, after who drives what.
    static var driveClickHint: String {
        String(localized: "sidebar.drive.clickHint", defaultValue: "Click to go there or stop it.", bundle: .module)
    }

    /// The drive indicator menu's first item: `Go to Claude Code`.
    static func driveGoTo(_ agent: String) -> String {
        String(localized: "sidebar.drive.goTo", defaultValue: "Go to \(agent)", bundle: .module)
    }

    /// The drive indicator menu's stop: a Computer Use session, or a chat's turn that drives a browser.
    static func driveStop(_ drive: SidebarDriveKind) -> String {
        switch drive {
        case .screen: String(localized: "sidebar.drive.stopComputerUse", defaultValue: "Stop Computer Use", bundle: .module)
        case .browser: String(localized: "sidebar.drive.stopAgent", defaultValue: "Stop Agent", bundle: .module)
        }
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
