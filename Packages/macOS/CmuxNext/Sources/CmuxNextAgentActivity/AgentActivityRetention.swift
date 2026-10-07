import Foundation

/// Supplies wall-clock time to activity retention code.
public protocol AgentActivityClock: Sendable {
    /// The current instant used for retention decisions.
    var now: Date { get }
}

/// The production wall clock for activity retention.
public struct SystemAgentActivityClock: AgentActivityClock, Sendable {
    public init() {}
    public var now: Date { Date() }
}

/// A persisted event's retention metadata.
public struct AgentActivityStoredEvent: Sendable, Hashable {
    public let id: String
    public let at: Date
    public let frameBlobs: [String]

    public init(id: String, at: Date, frameBlobs: [String] = []) {
        self.id = id
        self.at = at
        self.frameBlobs = frameBlobs
    }
}

/// A persisted thumbnail or frame's retention metadata.
public struct AgentActivityStoredFrame: Sendable, Hashable {
    public let blob: String
    public let capturedAt: Date

    public init(blob: String, capturedAt: Date) {
        self.blob = blob
        self.capturedAt = capturedAt
    }
}

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
