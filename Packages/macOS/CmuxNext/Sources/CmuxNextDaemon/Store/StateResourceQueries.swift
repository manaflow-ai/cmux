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
    public var servesStateResources: Bool { supports(DaemonCapabilities.shared.stateResources) }

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
        for await done in Observations({ self.appliedSequence >= sequence || self.connectionState != state }) where done {
            return
        }
    }

    /// Returns once the state resources' first snapshot arrived, or this
    /// daemon serves none (`SessionStateStore.known`), or the connection changed.
    public func sessionStateResolved() async {
        guard !session.known else { return }
        let state = connectionState
        for await done in Observations({ self.session.known || self.connectionState != state }) where done {
            return
        }
    }
}
