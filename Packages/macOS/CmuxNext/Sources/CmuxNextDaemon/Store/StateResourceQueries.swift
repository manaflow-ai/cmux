import CmuxNextCompat
import Foundation
import Observation

/// Read-only queries over a store's state resources and its applied event
/// sequence (`DaemonStore` conforms): whether the daemon serves the v2 state
/// operations, the public ids they take, and event-driven waits for the
/// mirror to catch up. Kept apart from the store's apply paths.
@MainActor
public protocol StateResourceQueries: AnyObject {
    var identity: DaemonIdentity? { get }
    var registryID: String? { get }
    var workspaces: [WorkspaceModel] { get }
    var session: SessionStateStore { get }
    var appliedSequence: UInt64 { get }
    var connectionState: DaemonConnectionState { get }
    func workspace(key: WorkspaceKey) -> WorkspaceModel?
}

extension StateResourceQueries {
    /// True when this daemon serves the state resources (closed history,
    /// ephemeral workspaces, workspace status, the v2 state mutations): its
    /// `identify` advertises `DaemonCapabilities.stateResources`.
    public var servesStateResources: Bool { supports(DaemonCapabilities.stateResources) }

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

    /// Returns once the tree reflects every event up to `sequence` (a
    /// `DaemonConnection.eventSequence()` taken after a command's reply), or
    /// the connection changed. Event-driven: it observes the store.
    public func applied(through sequence: UInt64?) async {
        guard let sequence, appliedSequence < sequence else { return }
        let state = connectionState
        for await done in ObservationStream({ self.appliedSequence >= sequence || self.connectionState != state }) where done {
            return
        }
    }

    /// Waits until the store applied every event up to `sequence` (``DaemonConnection/eventSequence()`` read
    /// after a command's reply) and says whether it did: false at once for no sequence (the connection lost
    /// `ready`: nothing bounds the events), and false when the connection changed since `epoch`
    /// (``connectionEpoch`` read in the same turn as the sequence) before the store got there: its events may
    /// never apply. The one read-your-writes wait; ``applied(through:)`` is its unchecked form.
    ///
    /// - Parameters:
    ///   - sequence: The event sequence after the reply.
    ///   - epoch: ``connectionEpoch`` read with it.
    /// - Returns: Whether the store holds every event up to `sequence`.
    public func appliedThrough(_ sequence: UInt64?, since epoch: Int) async -> Bool {
        guard let sequence else { return false }
        if appliedSequence >= sequence { return true }
        guard connectionEpoch == epoch else { return false }
        // connectionEpoch is not observed; every epoch change also sets connectionState, which is.
        for await done in ObservationStream({ (self.appliedSequence >= sequence, self.connectionState) }) {
            if done.0 { return true }
            if connectionEpoch != epoch { return false }
        }
        return appliedSequence >= sequence
    }

    /// Returns once the state resources' first snapshot arrived, or this
    /// daemon serves none (`SessionStateStore.known`), or the connection changed.
    public func sessionStateResolved() async {
        guard !session.known else { return }
        let state = connectionState
        for await done in ObservationStream({ self.session.known || self.connectionState != state }) where done {
            return
        }
    }
}
