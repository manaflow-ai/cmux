import Foundation

/// Read-only queries over a store's state resources and its applied event
/// sequence (`DaemonStore` conforms): whether the daemon serves the v2 state
/// operations and the public ids they take; the store's keyed waits for the
/// mirror to catch up follow. Kept apart from the store's apply paths.
@MainActor
public protocol StateResourceQueries: AnyObject {
    var identity: DaemonIdentity? { get }
    var registryID: String? { get }
    var workspaces: [WorkspaceModel] { get }
    var session: SessionStateStore { get }
    var appliedSequence: UInt64 { get }
    var connectionState: DaemonConnectionState { get }
    func workspace(key: WorkspaceKey) -> WorkspaceModel?
    /// Records a read-your-writes wait for `sequence` (``applied(through:)`` never waits on a script
    /// batch's stage: what it holds at or below `sequence` shows now, and it holds nothing the wait
    /// needs until ``endAppliedWait(_:)``).
    func beginAppliedWait(_ sequence: UInt64)
    /// Ends a wait ``beginAppliedWait(_:)`` recorded.
    func endAppliedWait(_ sequence: UInt64)
}

extension StateResourceQueries {
    /// True when this daemon serves the state resources (closed history,
    /// ephemeral workspaces, workspace status, the v2 state mutations): its
    /// `identify` advertises `DaemonCapability.stateResources`.
    public var servesStateResources: Bool { supports(DaemonCapability.stateResources.rawValue) }

    /// Whether this daemon's `identify` advertises `capability`.
    public func supports(_ capability: String) -> Bool {
        identity?.supports(capability) ?? false
    }

    /// Recently closed tabs, screens, and workspaces, newest first.
    public var closedItems: [ClosedItem] { session.closedItems }

    /// The public id of workspace `key` when this daemon takes the v2 state
    /// mutations for it, else nil (callers fall back to raw commands).
    public func stateResourceID(workspace key: WorkspaceKey) -> ResourceID? {
        servesStateResources ? workspace(key: key)?.resourceID : nil
    }

    /// The public id of workspace `key` of session `session` when this (home)
    /// daemon takes `workspace.place` for it: one of its own live workspaces.
    public func personalStateID(session: String, key: WorkspaceKey) -> ResourceID? {
        session == registryID ? stateResourceID(workspace: key) : nil
    }

    /// The workspace whose public id is `id`.
    public func workspace(resourceID id: ResourceID) -> WorkspaceModel? {
        workspaces.first { $0.resourceID == id }
    }
}

extension DaemonStore {
    /// How long ``sessionStateResolved()`` waits at most: a bound for its keyed wait, never reached by a daemon
    /// that answers (the stream's snapshot or its end comes within the connect).
    static let sessionStateWaitBound: Duration = .seconds(600)

    /// Returns once the tree reflects every event up to `sequence` (a
    /// `DaemonConnection.eventSequence()` taken after a command's reply), or
    /// the connection changed. Event-driven: the applied wait's continuation
    /// (``waitApplied(atLeast:since:)``), resumed by the apply that reaches it;
    /// a read-your-writes wait never waits on a script batch's stage.
    public func applied(through sequence: UInt64?) async {
        guard let sequence, appliedSequence < sequence else { return }
        _ = await waitApplied(atLeast: sequence, since: connectionEpoch)
    }

    /// Returns once the state resources' first snapshot arrived, or this
    /// daemon serves none (`SessionStateStore.known`), or the connection changed.
    /// A keyed wait on the connection slot (recipe R-wait, StoreWaiters), which
    /// the session stream settles when it becomes known.
    public func sessionStateResolved() async {
        guard !session.known else { return }
        let state = connectionState, session = session
        _ = await waitConnection(timeout: Self.sessionStateWaitBound) { now in session.known || now != state }
    }
}
