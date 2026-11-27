import Foundation

/// Channel message `snapshot_request` (sync-and-transport.md, "Channel
/// message: snapshot_request"): the viewer asks the host for a fresh
/// `snapshot_ready` over the terminal channel.
public struct SnapshotRequest: Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable {
        case digestMismatch = "digest_mismatch"
        case gap
        case generationMismatch = "generation_mismatch"
        case attach
    }

    /// What the viewer holds.
    public struct Have: Hashable, Sendable {
        public var generation: UInt32
        public var offset: UInt64
        public var snapshotVersion: UInt16

        public init(generation: UInt32, offset: UInt64, snapshotVersion: UInt16) {
            self.generation = generation
            self.offset = offset
            self.snapshotVersion = snapshotVersion
        }
    }

    public var terminal: String
    public var reason: Reason
    public var have: Have?
    /// Idempotency per viewer connection: the host collapses duplicates in flight.
    public var requestID: String

    public init(terminal: String, reason: Reason, have: Have?, requestID: String) {
        self.terminal = terminal
        self.reason = reason
        self.have = have
        self.requestID = requestID
    }

    /// The message body (`type` plus the spec fields; `have` is null when empty).
    public var json: [String: Any] {
        let have: Any = have.map {
            ["generation": $0.generation, "offset": $0.offset, "snapshot_version": $0.snapshotVersion] as [String: Any]
        } ?? NSNull()
        return ["type": "snapshot_request", "terminal": terminal, "reason": reason.rawValue,
                "have": have, "request_id": requestID]
    }
}
