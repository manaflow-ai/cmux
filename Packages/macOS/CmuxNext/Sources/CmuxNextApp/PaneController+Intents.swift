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
            TabMoves.toNewColumn(tab, anchor: pane, services: services)
        case .trailingButton(let id):
            services.tabBarButtons.perform(id, paneKey: paneKey)
        case .dragBegan(let start):
            services.dragSession.begin(start, from: self)
        case .groupDragBegan(let start):
            services.dragSession.beginGroup(start, from: self)
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

    /// New terminal tab in this pane. `typing` is sent to the new shell
    /// once the tab exists (config command actions). `keep` makes the
    /// terminal outlive the tab; by default the daemon ends it after the
    /// reap grace period once its last tab closes.
    func newTerminalTab(cwd: String? = nil, typing text: String? = nil, keep: Bool? = nil) {
        let handle = pane.handle
        let cwd = cwd ?? selectedTab?.cwd
        let workspace = services.workspaceKey(of: pane)
        guard let connection = daemon.connection else { return }
        services.registry.track(Task {
            do {
                let created = try await connection.newTab(in: handle, options: SpawnOptions(cwd: cwd, workspace: workspace, keep: keep))
                if let text { try await connection.send(created.surface, text: text) }
                pendingSelectSurface = created.surface
                apply(snapshot())
                return nil
            } catch {
                daemon.logger.error("new-tab failed: \(String(describing: error), privacy: .public)")
                return "new-tab: \(error)"
            }
        })
    }

    /// New browser tab: daemon-owned when supported (engine `requested`,
    /// WebKit by default, CEF when asked for and bundled), else
    /// session-local. The new tab is selected and focused when it lands; a
    /// blank tab focuses its address bar so the user can type a URL.
    func newBrowserTab(url: URL? = nil, engine requested: String? = nil) {
        let browserTabs = services.cache.browserTabs!
        if browserTabs.isAvailable() {
            let engine = browserTabs.engine(requested: requested)
            let handle = pane.handle
            services.registry.track(Task {
                do {
                    let surface = try await browserTabs.create(handle, url?.absoluteString ?? "about:blank", engine)
                    pendingSelectSurface = surface
                    if url == nil { pendingAddressBarFocus = surface }
                    apply(snapshot())
                    return nil
                } catch {
                    daemon.logger.error("new-frontend-browser-tab failed: \(String(describing: error), privacy: .public)")
                    return "new-frontend-browser-tab: \(error)"
                }
            })
            return
        }
        let local = LocalBrowserTab.make(url: url)
        state.localBrowserTabs[paneKey, default: []].append(local)
        apply(snapshot())
        select(StripTabID(local.id))
        if url == nil { services.cache.existingBrowser(local.id)?.chrome.perform(.focusAddressBar) }
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
            commands.append(daemon.closeCommand(for: tab))
        }
        apply(snapshot())
        guard !commands.isEmpty else { return }
        let keys = Set(ids.map(\.rawValue))
        services.registry.track(Task {
            var failed = false
            var unknown = false
            for command in commands {
                switch await daemon.runReportingTimeout(command.label, command.run) {
                case .succeeded: break
                case .failed: failed = true
                case .unknown: unknown = true
                }
            }
            // A close that missed its deadline under daemon load usually still
            // lands: keep the tabs hidden until a snapshot ordered after the
            // closes says which ones remain, instead of flashing them back.
            if unknown { await daemon.reconcile() }
            pendingClosed.subtract(keys)
            for key in keys { services.cache.release(key) }
            if failed || unknown { resyncStrip() }
            return failed ? "close failed (see the app log)" : nil
        })
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
        services.registry.track(Task {
            let ok = await daemon.perform("set-tab-pinned", patch: .setTabPinned(surface: surface, pinned: pinned)) { connection, _ in
                _ = try await connection.setTabPinned(surface, pinned)
            }
            if !ok { resyncStrip() }
            return ok ? nil : "set-tab-pinned failed (see the app log)"
        })
    }

    func rename(_ id: StripTabID) {
        guard let tab = tab(id), let window = view.window else { return }
        let surface = tab.surface
        RenamePrompt.run(title: Strings.renameTabTitle, initial: tab.displayTitle, in: window) { [daemon] name in
            Task {
                await daemon.perform("rename-surface", patch: .renameTab(surface: surface, name: name)) { connection, _ in
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
