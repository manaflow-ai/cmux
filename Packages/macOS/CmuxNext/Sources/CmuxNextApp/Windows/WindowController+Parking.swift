import AppKit
import CmuxNextAppCore
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextWakeups

// Parked workspaces (plans/cmux-next/tab-lifecycle.md): the workspaces this window showed most recently stay
// mounted and paused (`ParkedWorkspaceBudget`), so a switch back swaps its view in within the frame.
extension WindowController {
    /// The shown workspace, then the parked ones from the most recently shown, each with its theme scope.
    var mountedContents: [WorkspaceContentController] {
        (content.map { [$0] } ?? []) + parked.values.sorted { $0.parkedSerial > $1.parkedSerial }
    }

    /// Critical memory pressure: the parked workspaces leave (views, panes, observations; their
    /// terminal surfaces already left the warm set) and mount again when shown, with their
    /// view-only state (strip and screen bar scroll) reset. The one under a top page stays: it is
    /// this window's workspace. So do the ones on screen beside the shown one (`sidebar.multiView`).
    func releaseParked() {
        for (id, controller) in parked where !keepsParked(id) {
            parked[id] = nil
            controller.teardown()
        }
    }

    /// Workspace `id` hibernated (plans/cmux-next/workspace-hibernation-DESIGN.md): its parked content
    /// leaves (views, panes, observations) and mounts again, cold, when shown. Never the shown
    /// workspace, the one under a top page or one on screen beside it.
    func releaseParked(_ id: String) {
        guard id != state.workspaceID, !isOnScreenBeside(id), let controller = parked.removeValue(forKey: id) else { return }
        controller.teardown()
    }

    /// On screen beside the shown workspace: in the `sidebar.multiView` set, a shown docked workspace or the stage's
    /// workspace while a dock has the focus (`window.dockedWorkspaces`).
    func isOnScreenBeside(_ id: String) -> Bool {
        state.isOnScreenBeside(id)
    }

    /// Parks `controller`; past the budget the oldest leave, never `controller` itself (a page may cover it).
    /// `leaving` is the workspace about to show: `show` takes it out next, so it neither counts nor leaves.
    func park(_ controller: WorkspaceContentController, leaving: String? = nil) {
        parkSerial &+= 1
        controller.park(serial: parkSerial)
        parked[controller.workspace.id] = controller
        trimParked(keeping: controller.workspace.id, leaving: leaving)
    }

    /// Past `ParkedWorkspaceBudget.standard`'s capacity, the least recently parked workspaces leave as under
    /// critical pressure, so a window that visited hundreds keeps a bounded set mounted.
    private func trimParked(keeping parkedNow: String, leaving: String?) {
        let budget = ParkedWorkspaceBudget.standard
        let entries = parked.compactMap { $0.key == leaving ? nil : (id: $0.key, serial: $0.value.parkedSerial) }
        guard entries.count > budget.capacity else { return }
        let kept = Set(parked.keys.filter(keepsParked)).union([parkedNow])
        for id in budget.evictions(parked: entries, kept: kept) {
            parked.removeValue(forKey: id)?.teardown()
        }
    }

    /// The one under a top page (this window's workspace) and the ones on screen beside the shown one (multi-view, docks).
    private func keepsParked(_ id: String) -> Bool {
        (content == nil && id == state.workspaceID) || isOnScreenBeside(id)
    }
}

// The next Cmd-N's workspace view, built before the key (STATUS 15250; Chrome's spare renderer): the key main window
// builds it on the daemon's reserved workspace (`AgentTabStore.reserveWorkspace`) as idle work after a frame commit,
// mounted hidden and parked like a parked workspace's view; Cmd-N's show takes it (no build, no window entry).
extension WindowController {
    /// Builds the reserved view after this frame, when this is the active main window; other windows' and a stale one go then.
    func scheduleReservedContent() {
        guard services.windows.active === self else { return }
        AfterFrameCommit().run { [weak self] in
            guard let self, services.windows.active === self else { return }
            for other in services.windows.controllers where other !== self { other.dropReservedContent() }
            if let ready = reservedContent.ready, ready.daemon !== services.daemon || !ready.daemon.store.reserves(ready.workspace) { dropReservedContent() }
            reservedContent.fill()
        }
    }

    /// Cmd-N shows `workspace`: the view built for it before the key, if this window holds it.
    func takeReservedContent(showing workspace: WorkspaceModel, on daemon: DaemonService) -> WorkspaceContentController? {
        guard let ready = reservedContent.ready, ready.workspace === workspace, ready.daemon === daemon else { return nil }
        _ = reservedContent.take()
        ready.unpark()
        return ready
    }

    /// The reserved view leaves this window; the daemon's reservation stays for the key window.
    func dropReservedContent() { reservedContent.take()?.teardown() }

    /// `reservedContent`'s idle work: the daemon's reservation (made if none) and its view, hidden in the content area.
    func makeReservedContent() -> WorkspaceContentController? {
        let daemon = services.daemon, tabs = services.agentTabs
        guard services.windows.active === self, content != nil, daemon.store.isLoaded else { return nil }
        guard daemon.connection != nil else { tabs.releaseReservedWorkspace(on: daemon.store, .disconnected); return nil }
        // The press's own folder (a focused terminal's) replaces this one at the key when it differs.
        let cwd = WorkspaceSpawn().startFolder(roomFolder: services.machines.local.store.profile(state.profileID)?.defaults?.cwd, local: true, daemonDefault: daemon.defaultCwd)
        guard let reserved = tabs.reserveWorkspace(on: daemon, cwd: cwd) else { return nil }
        let controller = WorkspaceContentController(workspace: reserved.model, daemon: daemon, services: services, state: state, parked: true)
        let view = controller.contentView
        (view.isHidden, view.frame) = (true, root.contentHost.bounds)
        root.contentHost.addSubview(view, positioned: .below, relativeTo: nil)
        view.setParked(true)
        view.reparentRootedThemeScope()
        return controller
    }
}
