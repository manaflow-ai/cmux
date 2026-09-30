import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
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

    /// A user selection (strip click, shortcut, palette, CLI): goes through
    /// the focus coordinator, which selects and focuses (`applySelection`).
    func select(_ id: StripTabID, source: FocusEvent.Source = .intent) {
        guard let workspace else { return applySelection(id) }
        workspace.focus.send(.selectTab(pane: paneKey, tab: id.rawValue, source: source))
    }

    /// Makes `id` the selected tab and shows it on the next display frame.
    /// Called by the focus applier; never moves focus itself.
    ///
    /// The strip highlights the tab at once; the content follows once per
    /// frame, for whatever tab is selected by then. Holding Ctrl-Tab (key
    /// repeat, several selections per frame) therefore shows only the
    /// latest one and never creates, attaches or reveals content for a tab
    /// the user already moved past.
    func applySelection(_ id: StripTabID) {
        guard stripModel.selectedID != id || currentTabKey != id.rawValue, let state else { return }
        state.selection.select(id.rawValue, in: paneKey)
        stripModel.selectedID = id
        services.presentation.setNeedsShowSelected(self)
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
        let intent = self.workspace?.beginFocusIntent()
        services.registry.track(Task {
            do {
                let created = try await connection.newTab(in: handle, options: SpawnOptions(cwd: cwd, workspace: workspace, keep: keep))
                if let text { try await connection.send(created.surface, text: text) }
                pendingSelectSurface = created.surface
                apply(snapshot())
                self.workspace?.expectFocus(on: created.surface, generation: intent)
                return nil
            } catch {
                daemon.logger.error("new-tab failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("new-tab", error)
            }
        })
    }

    /// New browser tab: daemon-owned when supported, on the engine
    /// `BrowserTabService.resolve` picks (an explicit engine, else
    /// `browser.defaultEngine`, Chromium, with the WebKit fallback), else
    /// session-local. The new tab is selected and focused when it lands; a
    /// blank tab focuses its address bar so the user can type a URL.
    /// `inherited` is a reopened or duplicated tab's engine or a popup
    /// opener's (falls back instead of refusing). `adopting` is a popup page
    /// the engine already created (`BrowserPageRequests`). `background` (a
    /// page's Cmd-click) creates the tab without selecting it.
    func newBrowserTab(url: URL? = nil, engine requested: String? = nil, inherited: String? = nil,
                       adopting child: (any BrowserTab)? = nil, background: Bool = false) {
        let browserTabs = services.cache.browserTabs!
        if browserTabs.isAvailable() {
            var choice: BrowserEngineChoice
            switch browserTabs.resolve(requested: requested, inherited: inherited) {
            case .refuse(let reason): return services.registry.refuse(BrowserTabService.message(reason))
            case .open(let resolved): choice = resolved
            }
            if child != nil { choice = BrowserPageRequests.choice(adopting: child, inherited: inherited, browserTabs: browserTabs) }
            let pageRequests = services.cache.pageRequests
            let handle = pane.handle
            let intent = background ? nil : workspace?.beginFocusIntent()
            services.registry.track(Task {
                do {
                    let surface = try await browserTabs.open(choice, in: handle, url: url?.absoluteString ?? "about:blank")
                    if let child { pageRequests.adopt(child, surface: surface) }
                    guard !background else { return nil }
                    pendingSelectSurface = surface
                    apply(snapshot())
                    workspace?.expectFocus(on: surface, target: url == nil ? .addressBar : .content, generation: intent)
                    return nil
                } catch {
                    child?.close()
                    daemon.logger.error("new-frontend-browser-tab failed: \(String(describing: error), privacy: .public)")
                    return "new-frontend-browser-tab: \(error)"
                }
            })
            return
        }
        child?.close()  // Session-local tabs are WebKit pages made on demand.
        let local = LocalBrowserTab.make(url: url)
        state?.localBrowserTabs[paneKey, default: []].append(local)
        apply(snapshot())
        if background { return }
        select(StripTabID(local.id))
        if url == nil { workspace?.focus.send(.focusTarget(.addressBar, source: .intent)) }
    }

    /// Several tabs (close others, to the left, to the right) close in one
    /// daemon commit with `batch-close-v1` (`close-tabs`). Like a single
    /// close (`closeCommand`), it only detaches their terminals, so the daemon
    /// reaps them after its grace period and Reopen Closed Tab can show them
    /// again meanwhile. One tab, or an older daemon, takes one command per tab.
    func close(_ ids: [StripTabID]) {
        guard !ids.isEmpty else { return }
        var commands: [(label: String, run: @Sendable (DaemonConnection) async throws -> Void)] = []
        var surfaces: [SurfaceID] = []
        for id in ids {
            if id.rawValue.hasPrefix(LocalBrowserTab.prefix) {
                state?.localBrowserTabs[paneKey]?.removeAll { $0.id == id.rawValue }
                services.cache.release(id.rawValue)
                continue
            }
            guard let tab = tab(id) else { continue }
            pendingClosed.insert(tab.id)
            surfaces.append(tab.surface)
            commands.append(daemon.closeCommand(for: tab))
        }
        apply(snapshot())
        guard !commands.isEmpty else { return }
        let keys = Set(ids.map(\.rawValue))
        let runs = surfaces.count > 1 && daemon.supports(DaemonCapabilities.batchClose)
            ? [("close-tabs", { @Sendable [surfaces] connection in _ = try await connection.closeTabs(surfaces, endTerminals: false) })]
            : commands
        services.registry.track(Task {
            var failed = false
            var unknown = false
            for command in runs {
                switch await daemon.runReportingTimeout(command.0, command.1) {
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
        if target !== self { workspace?.focus.followMovedTab(tab.id, from: paneKey) }
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
        guard daemon.supports(DaemonCapabilities.tabMetadata) else {
            services.registry.refuse(daemon.missingCapabilityMessage(DaemonCapabilities.tabMetadata))
            return
        }
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
            let target = ActionTargetRef(kind: .tab, id: id.rawValue)
            guard let tab = tab(id), tab.kind == .browser else {
                return registry.makeContextMenu(for: .tab, target: target)
            }
            // A browser tab offers the engine it is not on.
            let other: ActionID = tab.browserEngine == BrowserEngineTag.cef.rawValue ? "browser.openInChromium" : "browser.openInWebKit"
            let entries = ContextMenuCatalog.entries(for: .tab).filter { $0 != .action(other) }
            return registry.makeContextMenu(for: .tab, target: target, entries: entries, implied: .browserFocused)
        case .group(let group), .savedGroup(let group):
            return registry.makeContextMenu(for: .tabGroup, target: ActionTargetRef(kind: .tabGroup, id: group.rawValue))
        case .emptyStrip:
            let entries = ContextMenuCatalog.entries(for: .newTab) + [.separator] + ContextMenuCatalog.entries(for: .pane)
            return registry.makeContextMenu(for: .pane, target: ActionTargetRef(kind: .pane, id: paneKey), entries: entries)
        case .newTabButton:
            // The engine menu predicts a Chromium tab (ChromiumWarmup).
            services.chromiumWarmup.chromiumLikely(.newTabMenu)
            return registry.makeContextMenu(for: .newTab, target: ActionTargetRef(kind: .pane, id: paneKey))
        }
    }
}
