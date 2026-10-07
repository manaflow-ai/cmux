import CmuxMobileWire

/// `terminal.snapshot_request` fields, or the host's own overflow resync.
public struct MobileSnapshotRequest: Hashable, Sendable {
    /// `digest_mismatch`, `gap`, `generation_mismatch` or `attach`.
    public var reason: String
    /// `{generation, offset, snapshot_version}` the viewer holds, or nil.
    public var have: JSONValue?
    public var requestID: String

    public init(reason: String, have: JSONValue?, requestID: String) {
        self.reason = reason
        self.have = have
        self.requestID = requestID
    }
}
