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
        do {
            let windowID = UUID().uuidString.lowercased()
            let workspace = try await windows.createWorkspace(WorkspaceSpawn(name: "Provider sign-in", command: line), on: machines.local, into: windowID)
            _ = windows.reveal(workspaceID: workspace)
            return true
        } catch { return false }
    }
    /// Opens a provider key page on this Mac, including when only remote windows exist.
    func openLocalProviderPage(_ url: URL) async -> Bool {
        var opened = false
        if inFrontPane({ opened = $0.newBrowserTab(url: url) }) { return opened }
        do {
            let windowID = UUID().uuidString.lowercased()
            let workspace = try await windows.createWorkspace(WorkspaceSpawn(name: "Provider sign-in", newTabPage: true), on: machines.local, into: windowID)
            guard let controller = windows.reveal(workspaceID: workspace), let pane = controller.focusedPane,
                  pane.daemon.isLocal else { return false }
            return pane.newBrowserTab(url: url)
        } catch { return false }
    }

    /// Chooses the active window's local pane first, then any other window's local pane.
    /// Accounts reads this Mac's sign-ins, so a remote pane is never a destination.
    @discardableResult
    func inFrontPane(_ open: (PaneController) -> Void) -> Bool {
        let active = windows.active
        let controllers = active.map { [$0] } ?? []
        for controller in controllers + windows.controllers.filter({ $0 !== active }) {
            guard let pane = LocalPanePick(focused: controller.focusedPane,
                                          others: controller.content.map { Array($0.panes.values) } ?? [],
                                          isLocal: { $0.daemon.isLocal }).pane else { continue }
            open(pane)
            windows.bringToFront(controller)
            return true
        }
        return false
    }
}
