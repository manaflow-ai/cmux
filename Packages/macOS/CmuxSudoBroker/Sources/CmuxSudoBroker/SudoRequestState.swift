public import Foundation

/// Durable lifecycle state shared by the app, CLI, and execution runner.
public struct SudoRequestState: Codable, Sendable, Equatable {
    /// The request identifier.
    public let id: String

    /// The current non-terminal phase.
    public let phase: SudoRequestPhase

    /// The last state transition date.
    public let updatedAt: Date

    /// The independent runner identity, once launched.
    public let runner: SudoProcessIdentity?

    /// The script process identity, once spawned.
    public let execution: SudoProcessIdentity?

    /// Process generations that survived the runner's bounded cleanup attempt.
    public let cleanupSurvivors: [SudoProcessIdentity]?

    /// Creates durable request state.
    ///
    /// - Parameters:
    ///   - id: The request identifier.
    ///   - phase: The current non-terminal lifecycle phase.
    ///   - updatedAt: The date of this state transition.
    ///   - runner: The independent runner identity, when known.
    ///   - execution: The spawned `script` wrapper identity, when known.
    ///   - cleanupSurvivors: Generations that require recovery on a later refresh.
    public init(
        id: String,
        phase: SudoRequestPhase,
        updatedAt: Date,
        runner: SudoProcessIdentity? = nil,
        execution: SudoProcessIdentity? = nil,
        cleanupSurvivors: [SudoProcessIdentity]? = nil
    ) {
        self.id = id
        self.phase = phase
        self.updatedAt = updatedAt
        self.runner = runner
        self.execution = execution
        self.cleanupSurvivors = cleanupSurvivors
    }
}
