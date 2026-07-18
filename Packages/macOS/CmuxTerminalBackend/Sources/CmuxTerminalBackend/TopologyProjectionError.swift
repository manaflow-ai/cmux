/// A continuity failure while projecting an authoritative topology stream.
public enum TopologyProjectionError: Error, Equatable, Sendable {
    /// A delta was applied before an authoritative snapshot was installed.
    case noSnapshot

    /// The persisted logical session changed across an authority fence.
    case sessionChanged(expected: SessionID, actual: SessionID)

    /// The daemon lifetime changed across an authority fence.
    case daemonChanged(expected: DaemonInstanceID, actual: DaemonInstanceID)

    /// A delta's base revision does not equal the installed revision.
    case revisionGap(expectedBase: UInt64, actualBase: UInt64)

    /// A delta does not advance its base revision by exactly one.
    case invalidRevision(base: UInt64, revision: UInt64)

    /// The backend instructed the client to discard local state and resnapshot.
    case resnapshotRequired(currentRevision: UInt64?, reason: TopologyResnapshotReason)
}
