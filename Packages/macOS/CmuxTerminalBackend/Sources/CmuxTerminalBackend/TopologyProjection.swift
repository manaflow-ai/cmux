internal import Foundation

/// A value projection that advances only after a delta has been validated and
/// reduced successfully. Callers cannot expose a new revision paired with old
/// state, or partially mutate live state before discovering a stream gap.
public struct TopologyProjection<State: Sendable>: Sendable {
    /// The authority that produced the installed snapshot, or `nil` before installation.
    public private(set) var authority: BackendAuthority?

    /// The revision paired atomically with ``value``, or `nil` before installation.
    public private(set) var revision: UInt64?

    /// The projected state at ``revision``, or `nil` before installation.
    public private(set) var value: State?

    /// Creates an empty projection that requires a snapshot before applying deltas.
    public init() {}

    /// Creates a projection from an authoritative snapshot and corresponding value.
    ///
    /// - Parameters:
    ///   - snapshot: The authoritative snapshot supplying authority and revision.
    ///   - value: The projected value corresponding exactly to the snapshot.
    public init(snapshot: TopologySnapshot, value: State) {
        authority = snapshot.authority
        revision = snapshot.revision
        self.value = value
    }

    /// Atomically replaces the projection with an authoritative snapshot and value.
    ///
    /// - Parameters:
    ///   - snapshot: The authoritative snapshot supplying authority and revision.
    ///   - value: The projected value corresponding exactly to the snapshot.
    public mutating func install(snapshot: TopologySnapshot, value: State) {
        authority = snapshot.authority
        revision = snapshot.revision
        self.value = value
    }

    /// Validates and atomically reduces one contiguous topology delta.
    ///
    /// - Parameters:
    ///   - delta: The next topology transaction to apply.
    ///   - reduce: A pure reduction from the current value and delta to a candidate value.
    /// - Throws: ``TopologyProjectionError`` for authority or revision discontinuity,
    ///   or any error thrown by `reduce`. The projection is unchanged on failure.
    public mutating func apply(
        _ delta: TopologyDelta,
        reduce: (State, TopologyDelta) throws -> State
    ) throws {
        guard let authority, let revision, let value else {
            throw TopologyProjectionError.noSnapshot
        }
        guard authority.sessionID == delta.authority.sessionID else {
            throw TopologyProjectionError.sessionChanged(
                expected: authority.sessionID,
                actual: delta.authority.sessionID
            )
        }
        guard authority.daemonInstanceID == delta.authority.daemonInstanceID else {
            throw TopologyProjectionError.daemonChanged(
                expected: authority.daemonInstanceID,
                actual: delta.authority.daemonInstanceID
            )
        }
        guard delta.baseRevision == revision else {
            throw TopologyProjectionError.revisionGap(
                expectedBase: revision,
                actualBase: delta.baseRevision
            )
        }
        guard revision != UInt64.max, delta.revision == revision + 1 else {
            throw TopologyProjectionError.invalidRevision(
                base: delta.baseRevision,
                revision: delta.revision
            )
        }

        let candidate = try reduce(value, delta)
        self.value = candidate
        self.revision = delta.revision
    }

    /// Invalidates the projection and throws the authoritative resnapshot reason.
    ///
    /// - Parameter response: The backend instruction requiring a new snapshot.
    /// - Throws: An authority-change error when the response crosses an authority
    ///   fence, otherwise ``TopologyProjectionError/resnapshotRequired(currentRevision:reason:)``.
    public mutating func requireResnapshot(_ response: BackendResnapshotRequired) throws {
        if let authority {
            guard authority.sessionID == response.authority.sessionID else {
                invalidate()
                throw TopologyProjectionError.sessionChanged(
                    expected: authority.sessionID,
                    actual: response.authority.sessionID
                )
            }
            guard authority.daemonInstanceID == response.authority.daemonInstanceID else {
                invalidate()
                throw TopologyProjectionError.daemonChanged(
                    expected: authority.daemonInstanceID,
                    actual: response.authority.daemonInstanceID
                )
            }
        }
        invalidate()
        throw TopologyProjectionError.resnapshotRequired(
            currentRevision: response.currentRevision,
            reason: response.reason
        )
    }

    /// Clears the authority, revision, and projected value.
    public mutating func invalidate() {
        authority = nil
        revision = nil
        value = nil
    }
}

public extension TopologyProjection where State == CanonicalTopology {
    /// Creates a canonical-topology projection directly from its snapshot.
    ///
    /// - Parameter snapshot: The authoritative canonical-topology snapshot.
    init(snapshot: TopologySnapshot) {
        self.init(snapshot: snapshot, value: snapshot.topology)
    }

    /// Installs the canonical topology contained by an authoritative snapshot.
    ///
    /// - Parameter snapshot: The authoritative canonical-topology snapshot.
    mutating func install(snapshot: TopologySnapshot) {
        install(snapshot: snapshot, value: snapshot.topology)
    }

    /// Applies one contiguous delta by installing its complete replacement topology.
    ///
    /// - Parameter delta: The next topology transaction to apply.
    /// - Throws: ``TopologyProjectionError`` when authority or revision continuity fails.
    mutating func apply(_ delta: TopologyDelta) throws {
        try apply(delta) { _, delta in delta.replacement }
    }
}
