import Foundation

// A chat row's subagents (`SidebarSubagentsView`): the stacked line's counts, "N more", and what
// VoiceOver says of each line. A line itself draws only its mark and title: no "Subagent" word on
// every child (design/sidebar.md, "Never repeat a type label on every child row").
extension Strings {
    /// The stacked line: what runs, else what finished, and what failed ("3 running · 1 failed", "8 done").
    static func subagentStack(_ strip: SidebarSubagentStrip) -> String {
        var parts: [String] = []
        if strip.running > 0 {
            parts.append(String(localized: "sidebar.subagents.stack.running", defaultValue: "\(strip.running) running", bundle: .module))
        } else if strip.done > 0 {
            parts.append(String(localized: "sidebar.subagents.stack.done", defaultValue: "\(strip.done) done", bundle: .module))
        }
        if strip.failed > 0 {
            parts.append(String(localized: "sidebar.subagents.stack.failed", defaultValue: "\(strip.failed) failed", bundle: .module))
        }
        return parts.joined(separator: " · ")
    }

    /// The line past a chat's last listed subagents.
    static func moreSubagents(_ count: Int) -> String {
        String(localized: "sidebar.subagents.more", defaultValue: "\(count) more", bundle: .module)
    }

    /// A subagent that gave no name or task.
    static var untitledSubagent: String {
        String(localized: "sidebar.subagents.untitled", defaultValue: "Subagent", bundle: .module)
    }

    /// A subagent's line, for VoiceOver: its title and where it stands.
    static func subagentRow(_ title: String, state: SidebarSubagent.State) -> String {
        let stateText = subagentState(state)
        return String(localized: "sidebar.subagents.a11y.row", defaultValue: "Subagent \(title), \(stateText)", bundle: .module)
    }

    static func subagentState(_ state: SidebarSubagent.State) -> String {
        switch state {
        case .running: String(localized: "sidebar.subagents.state.running", defaultValue: "running", bundle: .module)
        case .done: String(localized: "sidebar.subagents.state.done", defaultValue: "done", bundle: .module)
        case .failed: String(localized: "sidebar.subagents.state.failed", defaultValue: "failed", bundle: .module)
        case .stopped: String(localized: "sidebar.subagents.state.stopped", defaultValue: "stopped", bundle: .module)
        }
    }
}
