import CmuxNextAccounts
import CmuxNextActions
import CmuxNextAppCore
import CmuxNextWakeups
import Foundation

// A provider's own login or logout, run where the person can see and answer
// it. Settings is its own window, so a tab opened in the main window's
// focused pane stayed behind it: Re-authenticate and Sign In looked like
// they did nothing (Leo, 2026-10-19: "it only reads").
extension AppServices {
    /// Opens a provider login in a local pane, creating a local workspace when the current
    /// window has no local pane. The command never targets a remote machine.
    func openLocalProviderLogin(_ line: String) async -> Bool {
        var pane: PaneController?
        if inFrontPane({ pane = $0 }), let pane {
            guard pane.daemon.connection != nil else { return false }
            // The pane starts a tracked task for both creation and send. Capture it here,
            // inside the Accounts task, so its caller receives the actual outcome.
            let work = registry.capturingWork { pane.newTerminalTab(typing: line + "\r") }
            guard !work.isEmpty else { return false }
            return await providerWorkSucceeded(work)
        }
        do {
            let windowID = UUID().uuidString.lowercased()
            let workspace = try await windows.createWorkspace(WorkspaceSpawn(name: "Provider sign-in", command: line), on: machines.local, into: windowID)
            _ = windows.reveal(workspaceID: workspace)
            return true
        } catch { return false }
    }
    /// Opens a provider key page on this Mac, including when only remote windows exist.
    func openLocalProviderPage(_ url: URL) async -> Bool {
        var pane: PaneController?
        if inFrontPane({ pane = $0 }), let pane { return await openProviderPage(url, in: pane) }
        do {
            let daemon = machines.local
            guard let connection = daemon.connection else { return false }
            let windowID = UUID().uuidString.lowercased()
            let workspace = try await windows.createWorkspace(WorkspaceSpawn(name: "Provider sign-in", newTabPage: true), on: daemon, into: windowID)
            guard await daemon.appliedThroughReply(on: connection, after: "provider browser workspace"),
                  let controller = windows.reveal(workspaceID: workspace) else { return false }
            // The daemon reply precedes store delivery and pane mounting, especially in Classic
            // mode where no optimistic page exists. Observe mounting, closing and navigation;
            // the bounded wait removes its observer and timer when any of them finishes.
            let settled: @MainActor @Sendable () -> Bool = { [self] in
                _ = paneMounts.generation
                let mounted = controller.content?.workspace.id == workspace && controller.focusedPane != nil
                return mounted || daemon.connection !== connection
                    || windows.registry.value.window(controller.state.id)?.isOpen != true
                    || controller.state.workspaceID != workspace
            }
            if !settled() { await ObservationDeadline(owner: "provider-browser-pane").until(settled, limit: .seconds(10)) }
            guard !Task.isCancelled, controller.content?.workspace.id == workspace,
                  let pane = controller.focusedPane, pane.daemon.isLocal else { return false }
            return await openProviderPage(url, in: pane)
        } catch { return false }
    }

    private func openProviderPage(_ url: URL, in pane: PaneController) async -> Bool {
        var opened = false
        let work = registry.capturingWork { opened = pane.newBrowserTab(url: url) }
        guard opened else { return false }
        return await providerWorkSucceeded(work)
    }

    private func providerWorkSucceeded(_ work: [ActionWork]) async -> Bool {
        var succeeded = true
        for task in work { if await task.value != nil { succeeded = false } }
        return succeeded
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
