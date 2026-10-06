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
/// reports as visible. A found or staged update is never a card: it is the
/// compact control on the Settings row (``UpdateIndicatorPhase/badgeTitle``;
/// Lawrence 2026-10-05, "more minimal").
nonisolated public enum UpdateCard: Equatable, Sendable {
    /// The user asked to check.
    case checking
    /// The user asked and a found update downloads.
    case downloading(progress: Double?)
    /// The user clicked; the install waits for busy agents.
    case waiting(version: String?, busyAgents: Int)
    case installing
    /// The result of a check the user asked for.
    case note(String, isError: Bool)
}
