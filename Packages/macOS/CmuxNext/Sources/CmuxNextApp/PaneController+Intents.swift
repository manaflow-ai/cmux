import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTabs

// Tab strip intents -> daemon commands. Local-only state (selection,
// session browser tabs) changes in place; everything else is one command
// with an optimistic patch where the store has one.
extension PaneController {
    func handle(_ intent: TabStripIntent) {
        switch intent {
        case .select(let id):
            select(id)
        case .close(let id, _):
            close([id])
        case .closeOthers(let keep):
            close(stripModel.orderedTabs.filter { $0.id != keep && !$0.isPinned }.map(\.id))
        case .closeToRight(let id):
            let ids = orderedIDs
            guard let index = ids.firstIndex(of: id) else { return }
            close(Array(ids[(index + 1)...]))
        case .reorder(let id, _, let to):
            move(id, toPane: self, index: to)
        case .newTab:
            newTerminalTab()
        case .pin(let id), .unpin(let id):
            setPinned(id, pinned: { if case .pin = intent { true } else { false } }())
        case .rename(let id):
            rename(id)
        case .duplicate(let id):
            newTerminalTab(cwd: tab(id)?.cwd)
        case .moveToNewSplit(let id, let direction):
            guard let tab = tab(id) else { return }
            TabMoves.toNewSplit(tab, pane: pane, edge: direction == .right ? .right : .bottom, services: services)
        case .moveToNewColumn(let id):
            guard let tab = tab(id) else { return }
            TabMoves.toNewColumn(tab, rightOf: pane, services: services)
        case .dragBegan(let start):
            services.dragSession.begin(start, from: self)
        case .groupDragBegan(let start):
            // Whole-group drags need tab-groups-v1; end it at once.
            view.stripView.restoreDetachedGroup(start.groupID)
        case .toggleGroupCollapsed, .moveGroup, .addToGroup, .removeFromGroup, .group, .createGroup:
            handleGroup(intent)
        }
    }

    func select(_ id: StripTabID) {
        state.selection.select(id.rawValue, in: paneKey)
        stripModel.selectedID = id
        showSelected()
        focusContent()
        workspace?.paneDidFocus(self)
        services.windows.stateDidChange(state)
    }

    /// Selects the neighbor `offset` tabs away, wrapping.
    func selectAdjacent(_ offset: Int) {
        let ids = orderedIDs
        guard !ids.isEmpty else { return }
        let current = stripModel.selectedID.flatMap(ids.firstIndex(of:)) ?? 0
        select(ids[(current + offset % ids.count + ids.count) % ids.count])
    }

    func newTerminalTab(cwd: String? = nil) {
        let handle = pane.handle
        let cwd = cwd ?? selectedTab?.cwd
        guard let connection = services.daemon.connection else { return }
        Task {
            do {
                let created = try await connection.newTab(in: handle, options: SpawnOptions(cwd: cwd))
                pendingSelectSurface = created.surface
                apply(snapshot())
            } catch {
                services.daemon.logger.error("new-tab failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// New browser tab: daemon-owned when supported, else session-local.
    /// The omnibox takes focus so the user can type a URL or search.
    func newBrowserTab(url: URL? = nil) {
        let key: String
        if services.daemon.supports(DaemonCapabilities.frontendBrowserTabs) {
            let handle = pane.handle
            services.daemon.send("new-frontend-browser-tab") { connection in
                _ = try await connection.newFrontendBrowserTab(url: url?.absoluteString ?? "about:blank", engine: .webkit, in: handle)
            }
            return
        }
        let local = LocalBrowserTab.make(url: url)
        key = local.id
        state.localBrowserTabs[paneKey, default: []].append(local)
        apply(snapshot())
        select(StripTabID(key))
        if url == nil { services.cache.existingBrowser(key)?.chrome.perform(.focusAddressBar) }
    }

    func close(_ ids: [StripTabID]) {
        guard !ids.isEmpty else { return }
        var commands: [(label: String, run: @Sendable (DaemonConnection) async throws -> Void)] = []
        for id in ids {
            if id.rawValue.hasPrefix(LocalBrowserTab.prefix) {
                state.localBrowserTabs[paneKey]?.removeAll { $0.id == id.rawValue }
                services.cache.release(id.rawValue)
                continue
            }
            guard let tab = tab(id) else { continue }
            pendingClosed.insert(tab.id)
            if tab.kind == .pty, let terminal = tab.terminalID {
                let incarnation = tab.terminalIncarnation
                commands.append(("close-terminal", { try await $0.closeTerminal(terminal, incarnation: incarnation) }))
            } else {
                let surface = tab.surface
                commands.append(("close-surface", { try await $0.closeTab(surface) }))
            }
        }
        apply(snapshot())
        guard !commands.isEmpty else { return }
        let keys = Set(ids.map(\.rawValue))
        Task {
            var failed = false
            for command in commands where !(await services.daemon.run(command.label, command.run)) { failed = true }
            pendingClosed.subtract(keys)
            for key in keys { services.cache.release(key) }
            if failed { resyncStrip() }
        }
    }

    /// Moves a tab into `target` at `index` (display order), optimistic.
    func move(_ id: StripTabID, toPane target: PaneController, index: Int) {
        guard let tab = tab(id) else { return }
        TabMoves.move(tab, to: target.pane, index: index, services: services) { [weak self, weak target] ok in
            guard !ok else { return }
            self?.resyncStrip()
            target?.resyncStrip()
            self?.view.stripView.restoreDetachedTab(id)
        }
    }

    func setPinned(_ id: StripTabID, pinned: Bool) {
        guard let tab = tab(id) else { return }
        let surface = tab.surface
        Task {
            let ok = await services.daemon.perform("set-tab-pinned", patch: .setTabPinned(surface: surface, pinned: pinned)) { connection, _ in
                _ = try await connection.setTabPinned(surface, pinned)
            }
            if !ok { resyncStrip() }
        }
    }

    func rename(_ id: StripTabID) {
        guard let tab = tab(id), let window = view.window else { return }
        let surface = tab.surface
        RenamePrompt.run(title: Strings.renameTabTitle, initial: tab.displayTitle, in: window) { [services] name in
            Task {
                await services.daemon.perform("rename-surface", patch: .renameTab(surface: surface, name: name)) { connection, _ in
                    try await connection.renameTab(surface, to: name)
                }
            }
        }
    }

    // MARK: Context menus

    func contextMenu(for target: TabContextTarget) -> NSMenu? {
        let registry = services.registry
        switch target {
        case .tab(let id, _):
            select(id)
            return registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: id.rawValue))
        case .group(let group), .savedGroup(let group):
            return registry.makeContextMenu(for: .tabGroup, target: ActionTargetRef(kind: .tabGroup, id: group.rawValue))
        case .emptyStrip:
            return registry.makeContextMenu(for: .pane, target: ActionTargetRef(kind: .pane, id: paneKey))
        }
    }
}
