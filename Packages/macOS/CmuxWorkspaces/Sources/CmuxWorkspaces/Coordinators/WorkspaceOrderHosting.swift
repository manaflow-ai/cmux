public import Foundation

/// The window-side seam the reorder/group coordinators drive when the
/// sidebar workspace order changes observably. The per-window `TabManager`
/// is the single implementer; it posts the legacy
/// `workspaceOrderDidChange` NotificationCenter event and publishes the
/// reorder on the app event bus (both app-target concerns).
@MainActor
public protocol WorkspaceOrderHosting: AnyObject {
    /// Called after any mutation that moved workspaces, with the moved ids
    /// (legacy `postWorkspaceOrderDidChange(movedWorkspaceIds:)`). The host
    /// keeps the legacy empty-check guard.
    func workspaceOrderDidChange(movedWorkspaceIds: [UUID])
}
