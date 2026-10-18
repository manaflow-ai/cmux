import Foundation

/// Compact "time since" text for sidebar session rows: `<1m`, `12m`, `3h`, `2d`.
struct SidebarAgentSessionAgeFormatter {
    /// The widest strings the age column must fit, so the column has a fixed
    /// width and a ticking age never changes a row's height.
    static let columnTemplates = ["<1m ◀", "99d ◀"]

    func text(from date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 {
            return String(localized: "sidebar.agentSession.age.underMinute", defaultValue: "<1m")
        }
        if seconds < 3_600 {
            return String(localized: "sidebar.agentSession.age.minutes", defaultValue: "\(Int(seconds / 60))m")
        }
        if seconds < 86_400 {
            return String(localized: "sidebar.agentSession.age.hours", defaultValue: "\(Int(seconds / 3_600))h")
        }
        return String(localized: "sidebar.agentSession.age.days", defaultValue: "\(Int(seconds / 86_400))d")
    }
}
