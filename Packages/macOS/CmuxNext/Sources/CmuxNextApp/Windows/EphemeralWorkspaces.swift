import AppKit
import CmuxNextBrowser
import CmuxNextDaemon

// Incognito workspaces on a daemon with state resources are `ephemeral`
// (state-ownership.md 2): created with `workspace.create {ephemeral: true}`,
// recognized by the flag the daemon publishes, closed by the daemon at its
// next start and never recorded in closed history. The flag replaces the
// app's crash ledger (`IncognitoWorkspaceLedger`) for them: a workspace
// that comes back flagged after a crash, while the daemon kept running, is
// the daemon's to close (OWNERSHIP-PRINCIPLES.md); the app shows it in an
// incognito window, never a normal one, and never closes it.
@MainActor
enum EphemeralWorkspaces {
    /// True when `workspaceID` is flagged ephemeral by its daemon.
    static func isEphemeral(_ workspaceID: String, _ manager: WindowManager) -> Bool {
        manager.services.machines.workspace(id: workspaceID)?.0.ephemeral == true
    }

    /// The local daemon has said whether it serves state resources.
    static func localDaemonServes(_ manager: WindowManager) -> Bool { manager.services.daemon.store.servesStateResources }

    /// New incognito window on a daemon with state resources: an ephemeral
    /// workspace whose terminal tab is replaced by one incognito browser
    /// tab on `address`. The window waits in `pendingEphemeralWindows` for
    /// the workspace (reconcile gives it the first ephemeral orphan).
    static func newIncognitoWorkspace(_ manager: WindowManager, window windowID: String, address: String, choice: BrowserEngineChoice) {
        let daemon = manager.services.daemon
        let browserTabs = manager.services.cache.browserTabs
        manager.pendingEphemeralWindows.append(windowID)
        Task { @MainActor in
            defer {
                manager.pendingEphemeralWindows.removeAll { $0 == windowID }
                // Workspaces held back while this one was created get placed.
                manager.reconcileMembership()
                manager.endIncognitoSessionIfUnused()
            }
            guard let connection = daemon.connection else { return }
            do {
                let created = try await connection.state.createWorkspace(name: nil, ephemeral: true, terminal: true)
                await daemon.store.applied(through: await connection.eventSequence())
                guard let workspace = daemon.store.workspace(resourceID: created.workspaceID) else { return }
                manager.claimNew(workspaceID: workspace.id, window: windowID)
                let tab = workspace.screens.flatMap(\.panes).lazy.flatMap(\.tabs).first { $0.resourceID == created.tabID }
                guard let tab, let pane = daemon.store.pane(containing: tab.surface) else { return }
                _ = try await browserTabs.open(choice, in: pane.handle, url: address, incognito: true)
                try await connection.closeTab(tab.surface)
            } catch {
                daemon.logger.error("new incognito window failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Placements for ephemeral workspaces no window lists and no claim
    /// names: the incognito window waiting for one, else a new incognito
    /// window (a workspace another client made ephemeral).
    static func placements(_ manager: WindowManager, live: [String], placements: [String: String]) -> [String: String] {
        let registered = manager.registry.value
        var result: [String: String] = [:]
        var waiting = manager.pendingEphemeralWindows.filter { registered.window($0) == nil }
        for id in live where registered.owner(of: id) == nil && placements[id] == nil && !registered.discarding.contains(id) {
            guard isEphemeral(id, manager) else { continue }
            let window = waiting.isEmpty ? UUID().uuidString.lowercased() : waiting.removeFirst()
            manager.registry.apply { registry in
                registry.markIncognito(window)
                return WindowRegistry.Changes()
            }
            _ = manager.incognitoProfile()
            result[id] = window
        }
        return result
    }

    /// Waits until the local daemon's ephemeral flags are known (its state
    /// snapshot arrived, or it serves no state resources), so a workspace a
    /// crashed run left ephemeral goes to an incognito window, never a
    /// normal one. The daemon, not the app, closes it.
    static func awaitFlags(_ manager: WindowManager) async {
        guard manager.services.daemon.connection?.mirrorsSessionState == true else { return }
        await manager.services.daemon.store.sessionStateResolved()
    }
}
