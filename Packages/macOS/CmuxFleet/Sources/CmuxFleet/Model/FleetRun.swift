public import Foundation

/// Stores one supervised attempt for a Fleet task.
public struct FleetRun: Equatable, Codable, Sendable, Identifiable {
    /// The stable run identifier assigned by the engine.
    public var id: FleetRunID

    /// The task supervised by this attempt.
    public var taskID: FleetTaskID

    /// The one-based attempt number.
    public var attempt: Int

    /// The cmux workspace identifier used by the attempt.
    public var workspaceID: String

    /// The cmux surface identifier used by the attempt.
    public var surfaceID: String

    /// The agent session identifier, when hook events have established one.
    public var agentSessionID: String?

    /// The agent process identifier, when available.
    public var agentPID: Int32?

    /// The time the attempt started.
    public var startedAt: Date

    /// The last activity time observed during the attempt.
    public var lastActivityAt: Date

    /// The time the attempt ended, when finished.
    public var endedAt: Date?

    /// The reason the attempt ended, when finished.
    public var endReason: FleetRunEndReason?

    /// Creates a supervised Fleet run attempt snapshot.
    /// - Parameters:
    ///   - id: The stable run identifier assigned by the engine.
    ///   - taskID: The task supervised by this attempt.
    ///   - attempt: The one-based attempt number.
    ///   - workspaceID: The cmux workspace identifier used by the attempt.
    ///   - surfaceID: The cmux surface identifier used by the attempt.
    ///   - agentSessionID: The agent session identifier.
    ///   - agentPID: The agent process identifier.
    ///   - startedAt: The time the attempt started.
    ///   - lastActivityAt: The last activity time observed during the attempt.
    ///   - endedAt: The time the attempt ended.
    ///   - endReason: The reason the attempt ended.
    public init(
        id: FleetRunID,
        taskID: FleetTaskID,
        attempt: Int,
        workspaceID: String,
        surfaceID: String,
        agentSessionID: String? = nil,
        agentPID: Int32? = nil,
        startedAt: Date,
        lastActivityAt: Date,
        endedAt: Date? = nil,
        endReason: FleetRunEndReason? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.attempt = attempt
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.agentSessionID = agentSessionID
        self.agentPID = agentPID
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.endedAt = endedAt
        self.endReason = endReason
    }
}
