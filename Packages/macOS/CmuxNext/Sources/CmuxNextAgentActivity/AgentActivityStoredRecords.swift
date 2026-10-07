import Foundation

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
