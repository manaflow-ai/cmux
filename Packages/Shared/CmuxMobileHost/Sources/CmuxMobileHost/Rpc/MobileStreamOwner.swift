import CmuxMobileWire

/// A Mac-owned stream served to phones and the `HostDO` uplink
/// (`workspace:<host>`, `task:<host>`): seq, epoch, snapshot, updates.
public protocol MobileStreamOwner: Sendable {
    nonisolated var stream: String { get }
    var headSeq: UInt64 { get async }
    func snapshotFrame(decided: [DecidedKey]) async throws -> SnapshotFrame
    func updates(afterSeq: UInt64?, epoch: String?) async throws -> AsyncStream<WorkspaceStreamUpdate>
    nonisolated func stamped(_ frame: MobileFrame) throws -> JSONValue
}

extension WorkspaceStreamOwner: MobileStreamOwner {}
