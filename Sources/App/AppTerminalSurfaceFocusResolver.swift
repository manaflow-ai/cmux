import AppKit
import CmuxSidebar
import Foundation

/// App-side conformer for `TerminalSurfaceFocusResolving`. Bridges the main-window
/// focus controller's terminal-surface focus queries to the app-target Ghostty
/// view resolution (`cmuxOwningGhosttyView(for:)`) and the terminal surface
/// registry singleton (`GhosttyApp.terminalSurfaceRegistry`).
///
/// Holds no state: it is constructed at the composition root and injected into
/// `MainWindowFocusController`.
@MainActor
final class AppTerminalSurfaceFocusResolver: TerminalSurfaceFocusResolving {
    func owningTerminalSurfaceFocus(for responder: NSResponder?) -> TerminalSurfaceFocusOwner? {
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let workspaceId = ghosttyView.tabId,
              let panelId = ghosttyView.terminalSurface?.id else {
            return nil
        }
        return TerminalSurfaceFocusOwner(workspaceId: workspaceId, panelId: panelId)
    }

    func isRightSidebarDockSurface(id: UUID) -> Bool {
        GhosttyApp.terminalSurfaceRegistry.isRightSidebarDockSurface(id: id)
    }
}
