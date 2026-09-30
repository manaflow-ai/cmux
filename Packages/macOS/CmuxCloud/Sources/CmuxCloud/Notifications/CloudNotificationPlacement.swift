import CmuxSurfaceCatalogModel
import Foundation

/// Which local notification records a read action covers, in the local
/// store's own terms. Mirrors `TerminalNotification.matches(tabId:surfaceId:)`:
/// `.workspace` covers every record in the workspace, `.surface` with a nil
/// surface covers only the workspace-level records, and `.all` covers
/// everything. Cloud rows are placed with the same vocabulary, so a read of a
/// target also covers the rows that would land there.
public enum NotificationReadTarget: Equatable, Sendable {
    case all
    case workspace(UUID)
    case surface(workspaceID: UUID, surfaceID: UUID?)
}

extension CloudNotificationDeliveryTarget {
    /// Whether a read of `target` covers a row placed here, by the rule the
    /// store applies to its own records.
    func isCovered(by target: NotificationReadTarget) -> Bool {
        switch target {
        case .all:
            return true
        case .workspace(let workspaceID):
            return self.workspaceID == workspaceID
        case .surface(let workspaceID, let surfaceID):
            return self.workspaceID == workspaceID && panelID == surfaceID
        }
    }
}

/// A local workspace bound to a machine, as the placement resolver sees it.
public struct CloudNotificationBoundWorkspace: Equatable, Sendable {
    public init(
        workspaceID: UUID,
        remoteWorkspaceID: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.remoteWorkspaceID = remoteWorkspaceID
    }

    public let workspaceID: UUID
    public let remoteWorkspaceID: String?
}

/// Where one of a machine's notifications lands on this Mac, resolved from the
/// catalog as it is right now, never from the placement at delivery time. The
/// same resolver answers both "where does this row go" at delivery and "which
/// rows does a read of this workspace or pane cover" at dismissal, so the two
/// can never disagree.
@MainActor
public struct CloudNotificationPlacementResolver: Sendable {
    public init(
        machine: SurfaceMachineID,
        projections: @escaping @MainActor (SurfaceResourceID) -> [SurfaceProjection],
        remoteWorkspaceID: @escaping @MainActor (_ terminalID: String) -> String?,
        boundWorkspaces: @escaping @MainActor () -> [CloudNotificationBoundWorkspace]
    ) {
        self.machine = machine
        self.projections = projections
        self.remoteWorkspaceID = remoteWorkspaceID
        self.boundWorkspaces = boundWorkspaces
    }

    public let machine: SurfaceMachineID
    /// Local panes showing a resource of this machine.
    public var projections: @MainActor (SurfaceResourceID) -> [SurfaceProjection]
    /// The remote workspace whose tab shows the terminal, from the accepted graph.
    public var remoteWorkspaceID: @MainActor (_ terminalID: String) -> String?
    /// Local workspaces bound to the machine, in sidebar order.
    public var boundWorkspaces: @MainActor () -> [CloudNotificationBoundWorkspace]

    /// The pane showing the terminal when one is open on this Mac, else the
    /// local workspace standing for the terminal's remote workspace. A
    /// terminal in a remote workspace the person has not opened here has no
    /// local home: the row stays undelivered until one exists and the Cloud
    /// tree dot is its indicator, instead of stacking onto whichever local
    /// workspace happens to be bound to the machine (a workspace row then
    /// badges the whole machine's notifications, manaflow-ai/cmux#13000).
    /// Only a machine-level row (no terminal) lands on any local workspace
    /// bound to the machine. A terminal the accepted graph places in no
    /// workspace fails closed the same way: an unknown placement is not a
    /// machine-level one.
    public func target(for row: CloudVMNotificationRow) -> CloudNotificationDeliveryTarget? {
        let bound = boundWorkspaces()
        guard let terminalID = row.terminalID else {
            return bound.first.map { CloudNotificationDeliveryTarget(workspaceID: $0.workspaceID, panelID: nil) }
        }
        let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
        if let projection = projections(resource).first {
            return CloudNotificationDeliveryTarget(workspaceID: projection.workspaceID, panelID: projection.panelID)
        }
        guard let remoteWorkspaceID = remoteWorkspaceID(terminalID) else { return nil }
        return bound.first { $0.remoteWorkspaceID == remoteWorkspaceID }
            .map { CloudNotificationDeliveryTarget(workspaceID: $0.workspaceID, panelID: nil) }
    }
}
