import Foundation

/// The files that may be removed by one retention pass.
public struct AgentActivityRetentionPlan: Sendable, Equatable {
    public let eventIDs: [String]
    public let frameBlobs: [String]

    public init(eventIDs: [String], frameBlobs: [String]) {
        self.eventIDs = eventIDs
        self.frameBlobs = frameBlobs
    }
}

/// D19's event and thumbnail retention policy.
public struct AgentActivityRetentionPlanner: Sendable {
    public static let eventLifetime: TimeInterval = 30 * 86_400
    public static let frameLifetime: TimeInterval = 7 * 86_400

    private let clock: any AgentActivityClock

    /// Creates a planner with an injected clock so expiry is deterministic in tests.
    public init(clock: any AgentActivityClock) {
        self.clock = clock
    }

    /// Plans expired events and frames without touching the filesystem.
    public func plan(events: [AgentActivityStoredEvent], frames: [AgentActivityStoredFrame]) -> AgentActivityRetentionPlan {
        let now = clock.now
        let expiredEvents = events.filter { now.timeIntervalSince($0.at) >= Self.eventLifetime }
        let referencedByExpiredEvents = Set(expiredEvents.flatMap(\.frameBlobs))
        let expiredFrames = frames.filter {
            now.timeIntervalSince($0.capturedAt) >= Self.frameLifetime || referencedByExpiredEvents.contains($0.blob)
        }
        return AgentActivityRetentionPlan(
            eventIDs: expiredEvents.map(\.id),
            frameBlobs: expiredFrames.map(\.blob))
    }
}
