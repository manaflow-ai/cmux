import Foundation

/// Read-only queries over a store's state resources and its applied event
/// sequence (`DaemonStore` conforms): whether the daemon serves the v2 state
/// operations and the public ids they take. Kept apart from the store's
/// apply paths (the waits for the mirror to catch up are the store's own:
/// ``DaemonStore/appliedThrough(_:since:)``, ``DaemonStore/sessionStateResolved()``).
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
