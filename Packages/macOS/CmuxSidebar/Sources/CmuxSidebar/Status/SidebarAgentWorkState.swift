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
/// running row. An unrecognized value is not accepted anywhere: the control
/// socket rejects the whole `set_status` with an error, the same way it
/// already rejects an unknown `--format` or a non-integer `--priority`. A
/// future fourth state therefore needs the app to ship before the CLI that
/// sends it.
public enum SidebarAgentWorkState: String, Sendable, Equatable, CaseIterable {
    /// The agent itself is working: a model turn or a tool call is in flight.
    case running
    /// The agent is working through background subagents it spawned.
    case subagents
    /// The turn is over but the agent is parked on a deterministic external
    /// event it will be woken by: a background command, a scheduled wakeup, a
    /// CI run. Not idle, and not hibernatable.
    case waiting

    /// Parses a reported value, tolerating surrounding space and case and
    /// nothing else. Deliberately the same acceptance set as the control
    /// socket's own `--work` parse, so a value the socket rejects can never
    /// look parseable here.
    public static func parse(_ rawValue: String) -> SidebarAgentWorkState? {
        SidebarAgentWorkState(
            rawValue: rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        )
    }
}
