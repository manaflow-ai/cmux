import Foundation

/// What an update relaunch would interrupt, as the App reports it from the
/// daemon's agent states (event-driven; never polled).
nonisolated public struct UpdateBlockers: Equatable, Sendable {
    /// Agents in a turn (`AgentState.working`).
    public var busyAgents: Int

    public init(busyAgents: Int = 0) {
        self.busyAgents = max(0, busyAgents)
    }

    public static let none = UpdateBlockers()
    public var isEmpty: Bool { busyAgents == 0 }
}

/// The card above Settings for the update, or what `cmux update status`
/// reports as visible.
nonisolated public enum UpdateCard: Equatable, Sendable {
    /// The user asked to check.
    case checking
    /// The user asked and a found update downloads.
    case downloading(progress: Double?)
    /// Found, not downloaded: one click downloads and installs.
    case available(version: String?)
    /// Downloaded and verified: one click installs and relaunches.
    case ready(version: String?)
    /// The user clicked; the install waits for busy agents.
    case waiting(version: String?, busyAgents: Int)
    case installing
    /// The result of a check the user asked for.
    case note(String, isError: Bool)
}
