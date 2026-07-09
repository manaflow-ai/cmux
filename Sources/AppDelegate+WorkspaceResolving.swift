import CmuxTerminalCore
import Foundation

// The app delegate is the `WorkspaceResolving` witness: terminal surfaces map
// their owning-tab id to the concrete `Workspace` through this seam (injected at
// launch into the transitional `GhosttyApp` composition root) instead of
// reaching up to the `AppDelegate.shared` singleton.
extension AppDelegate: WorkspaceResolving {
    /// Resolves the `Workspace` that owns `tabId`, or `nil` when none is registered.
    ///
    /// Forwards to the existing `workspaceFor(tabId:)` lookup; the seam exists so
    /// `TerminalSurface.owningWorkspace()` no longer reads a global singleton.
    func workspace(forTabId tabId: UUID) -> Workspace? {
        workspaceFor(tabId: tabId)
    }
}
