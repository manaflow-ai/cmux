internal import Foundation

/// What a running agent is running on (the typed twin of the app's
/// `SidebarAgentWorkState`; raw values match so the conformance can rebuild
/// the app enum losslessly).
public enum ControlSidebarAgentWorkState: String, Sendable, Equatable, CaseIterable {
    /// The agent itself is working.
    case running
    /// The agent is working through background subagents.
    case subagents
    /// The agent is parked on a deterministic external event.
    case waiting
}
