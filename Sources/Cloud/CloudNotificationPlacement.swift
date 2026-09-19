import Foundation

/// Which local notification records a read action covers, in the local
/// store's own terms. Mirrors `TerminalNotification.matches(tabId:surfaceId:)`:
/// `.workspace` covers every record in the workspace, `.surface` with a nil
/// surface covers only the workspace-level records, and `.all` covers
/// everything. Cloud rows are placed with the same vocabulary, so a read of a
/// target also covers the rows that would land there.
enum NotificationReadTarget: Equatable, Sendable {
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
struct CloudNotificationBoundWorkspace: Equatable, Sendable {
    let workspaceID: UUID
    let remoteWorkspaceID: String?
}

/// Where one of a machine's notifications lands on this Mac, resolved from the
/// catalog as it is right now, never from the placement at delivery time. The
/// same resolver answers both "where does this row go" at delivery and "which
/// rows does a read of this workspace or pane cover" at dismissal, so the two
/// can never disagree.
@MainActor
struct CloudNotificationPlacementResolver {
    let machine: SurfaceMachineID
    /// Local panes showing a resource of this machine.
    var projections: @MainActor (SurfaceResourceID) -> [SurfaceProjection]
    /// The remote workspace whose tab shows the terminal, from the accepted graph.
    var remoteWorkspaceID: @MainActor (_ terminalID: String) -> String?
    /// Local workspaces bound to the machine, in sidebar order.
    var boundWorkspaces: @MainActor () -> [CloudNotificationBoundWorkspace]

    /// The pane showing the terminal when one is open on this Mac, else the
    /// local workspace bound to the terminal's remote workspace, else any local
    /// workspace bound to the machine. No local placement means the row stays
    /// undelivered until one exists; the Cloud tree still shows the dot.
    func target(for row: CloudVMNotificationRow) -> CloudNotificationDeliveryTarget? {
        if let terminalID = row.terminalID {
            let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
            if let projection = projections(resource).first {
                return CloudNotificationDeliveryTarget(workspaceID: projection.workspaceID, panelID: projection.panelID)
            }
        }
        let bound = boundWorkspaces()
        if let remoteWorkspaceID = row.terminalID.flatMap(remoteWorkspaceID),
           let exact = bound.first(where: { $0.remoteWorkspaceID == remoteWorkspaceID }) {
            return CloudNotificationDeliveryTarget(workspaceID: exact.workspaceID, panelID: nil)
        }
        return bound.first.map { CloudNotificationDeliveryTarget(workspaceID: $0.workspaceID, panelID: nil) }
    }
}
