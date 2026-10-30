import CmuxNextAccounts
import CmuxNextAppCore
import Foundation

// A provider's own login or logout, run where the person can see and answer
// it. Settings is its own window, so a tab opened in the main window's
// focused pane stayed behind it: Re-authenticate and Sign In looked like
// they did nothing (Leo, 2026-10-19: "it only reads").
extension AppServices {
    /// Opens a provider login in a local pane, creating a local workspace when the current
    /// window has no local pane. The command never targets a remote machine.
    func openLocalProviderLogin(_ line: String) async -> Bool {
        if inFrontPane({ $0.newTerminalTab(typing: line + "\r") }) { return true }
        for controller in windows.controllers {
            if let pane = LocalPanePick(focused: controller.focusedPane,
                                        others: controller.content.map { Array($0.panes.values) } ?? [],
                                        isLocal: { $0.daemon.isLocal }).pane {
                pane.newTerminalTab(typing: line + "\r")
                windows.bringToFront(controller)
                return true
            }
        }
        do {
            let windowID = UUID().uuidString.lowercased()
            let workspace = try await windows.createWorkspace(WorkspaceSpawn(name: "Provider sign-in", command: line), on: machines.local, into: windowID)
            _ = windows.reveal(workspaceID: workspace)
            return true
        } catch { return false }
    }
    /// Opens a tab in the main window's focused pane with `open` and brings
    /// that window forward. Accounts reads this Mac's sign-ins, so the tab
    /// is on this Mac: the focused pane when it is local, else another local
    /// pane of the window. False without one.
    @discardableResult
    func inFrontPane(_ open: (PaneController) -> Void) -> Bool {
        guard let controller = windows.active, let pane = LocalPanePick(focused: controller.focusedPane, others: controller.content.map { Array($0.panes.values) } ?? [], isLocal: { $0.daemon.isLocal }).pane else { return false }
        open(pane)
        windows.bringToFront(controller)
        return true
    }
}
