public import Foundation

/// What a *running* agent is running on, as reported by its hook.
///
/// This refines the running half of the sidebar's agent vocabulary; it never
/// replaces it. Needs input, idle and error stay where they already live (the
/// lifecycle state and the entry's own icon), and hibernation keeps reading
/// `AgentHibernationLifecycleState`, so a work state can never make a pane
/// with live work look hibernatable.
///
/// An entry without a work state reads exactly as it did before: a plain
/// running row. An unrecognized value from a newer CLI parses to `nil` and
/// degrades the same way.
public enum SidebarAgentWorkState: String, Sendable, Equatable, CaseIterable {
    /// The agent itself is working: a model turn or a tool call is in flight.
    case running
    /// The agent is working through background subagents it spawned.
    case subagents
    /// The turn is over but the agent is parked on a deterministic external
    /// event it will be woken by: a background command, a scheduled wakeup, a
    /// CI run. Not idle, and not hibernatable.
    case waiting

    /// Parses a reported value, tolerating case and `-`/`_` spelling.
    public static func parse(_ rawValue: String) -> SidebarAgentWorkState? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "running": return .running
        case "subagents", "subagent": return .subagents
        case "waiting": return .waiting
        default: return nil
        }
    }
}
