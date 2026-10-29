import AppKit
import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextDaemon
import CmuxNextWakeups

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
    static func newIncognitoWorkspace(_ manager: WindowManager, window windowID: String, address: String, choice: BrowserEngineChoice,
                                      space: ProfileID? = nil) {
        let services = manager.services, daemon = services.daemon, logger = daemon.logger
        let browserTabs = services.cache.browserTabs, mainWork = services.mainWork
        manager.pendingEphemeralWindows.append(windowID)
        guard let connection = daemon.connection else { return createdWorkspace(manager, window: windowID) }
        // The person's new window: the daemon's replies are awaited off main, each main step is a task of its own.
        // All of it runs in the caller's action scopes, so its run waits for the commands and a retry replays them.
        let scopes = ActionScopes.current
        services.work.task(.userBlocking) {
            await scopes.awaiting {
                do {
                    let created = try await connection.state.createWorkspace(name: nil, ephemeral: true, terminal: true, focus: true)
                    await daemon.appliedThroughReply(on: connection, after: "create incognito workspace")
                    // New Incognito Space: the workspace is pinned to that space before the window claims it.
                    if let space, let key = await mainWork.apply(.visible, owner: "EphemeralWorkspaces.key", {
                        daemon.store.workspace(resourceID: created.workspaceID)?.key
                    }) {
                        try await manager.pinToIncognitoSpace(key, space, on: daemon)
                    }
                    let claimed = await mainWork.apply(.visible, owner: "EphemeralWorkspaces.claim") { () -> ClaimedTab? in
                        scopes.applying { EphemeralWorkspaces.claim(manager, window: windowID, created: created) }
                    }
                    if let claimed {
                        _ = try await browserTabs.open(choice, in: claimed.pane, on: daemon, url: address, incognito: true)
                        try await connection.closeTab(claimed.tab)
                    }
                } catch {
                    logger.error("new incognito window failed: \(String(describing: error), privacy: .public)")
                }
                mainWork.postFromAnyThread(.visible, owner: "EphemeralWorkspaces.created") {
                    scopes.applying { EphemeralWorkspaces.createdWorkspace(manager, window: windowID) }
                }
            }
        }
    }

    /// Gives the created workspace to the new incognito window; returns its terminal tab and pane.
    private static func claim(_ manager: WindowManager, window windowID: String, created: StateResourceClient.CreatedWorkspace) -> ClaimedTab? {
        let store = manager.services.daemon.store
        guard let workspace = store.workspace(resourceID: created.workspaceID) else { return nil }
        manager.claimNew(workspaceID: workspace.id, window: windowID)
        let tab = workspace.screens.flatMap(\.panes).lazy.flatMap(\.tabs).first { $0.resourceID == created.tabID }
        guard let tab, let pane = store.pane(containing: tab.surface) else { return nil }
        return ClaimedTab(tab: tab.surface, pane: pane.handle)
    }

    /// The new workspace's terminal tab, which the browser tab replaces, and its pane.
    private nonisolated struct ClaimedTab: Sendable {
        let tab: SurfaceID
        let pane: PaneID
    }

    /// The new incognito window's workspace exists (or its creation ended): workspaces held back while
    /// it was created get placed.
    private static func createdWorkspace(_ manager: WindowManager, window windowID: String) {
        manager.pendingEphemeralWindows.removeAll { $0 == windowID }
        manager.reconcileMembership()
        manager.endIncognitoSessionIfUnused()
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
