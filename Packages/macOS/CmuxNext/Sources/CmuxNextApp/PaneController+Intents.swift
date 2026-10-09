import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTabs

// Tab strip intents -> daemon commands. Local-only state (selection,
// session browser tabs) changes in place; everything else is one command
// shown at once through a store intent where the store has one.
extension PaneController {
    func handle(_ intent: TabStripIntent) {
        switch intent {
        case .select(let id):
            select(id)
        case .close(let id, _):
            CloseUndoToasts.close(in: self, [id])
        case .closeOthers(let keep):
            CloseUndoToasts.close(in: self, stripModel.orderedTabs.filter { $0.id != keep && !$0.isPinned }.map(\.id))
        case .closeToRight(let id):
            let ids = orderedIDs
            guard let index = ids.firstIndex(of: id) else { return }
            CloseUndoToasts.close(in: self, Array(ids[(index + 1)...]))
        case .reorder(let id, _, let to):
            StripOrder.reorder(id, to: to, in: self)
        case .newTab(_, let opensWorkspace):
            StripNewTab.request(pane: paneKey, opensWorkspace: opensWorkspace) { _ = services.registry.perform($0, invocation: $1) }
        case .pin(let id), .unpin(let id):
            setPinned(id, pinned: { if case .pin = intent { true } else { false } }())
        case .rename(let id):
            rename(id)
        case .renameCommitted(let id, let name):
            commitRename(id, name: name)
        case .duplicate(let id):
            newTerminalTab(cwd: tab(id)?.cwd)
        case .moveToNewSplit(let id, let direction):
            guard let tab = tab(id) else { return }
            TabMoves.toNewSplit(tab, pane: pane, edge: direction == .right ? .right : .bottom, services: services)
        case .moveToNewColumn(let id):
            guard let tab = tab(id) else { return }
            TabMoves.toNewColumn(tab, anchor: pane, services: services)
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
    /// An action run without view-change permission selects nothing.
    func select(_ id: StripTabID, source: FocusEvent.Source = .intent) {
        // A user's tab switch may end link-tab opener relations (Chrome's rule).
        if source.isUserIntent, stripModel.selectedID != id {
            services.cache.pageRequests.openers.userActivated(from: selectedTab?.surface, to: tab(id)?.surface)
        }
        guard let workspace else {
            guard ActionRunScope.viewChangeAllowed() else { return }
            return applySelection(id)
        }
        workspace.focus.send(.selectTab(pane: paneKey, tab: id.rawValue, source: source))
    }

    /// Selects `id` and shows it; called by the focus applier, never moves focus.
    func applySelection(_ id: StripTabID) {
        guard stripModel.selectedID != id || currentTabKey != id.rawValue, let state else { return }
        state.selection.select(id.rawValue, in: paneKey)
        stripModel.selectedID = id
        PaneSelectionPresenter(pane: self).present()
        services.windows.recordSaver.stateDidChange(state)
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
    /// reap grace period once its last tab closes. `fromSelectedTab` (New
    /// Terminal Tab itself) starts it in a selected agent's cwd (#16620);
    /// other callers (config commands, account logins) keep the pane's.
    /// `typingAhead` names a new tab page whose `!` type-ahead the shell
    /// gets after `typing`, drained until nothing new arrived (NewTabTypeAhead).
    /// `then` runs once the new tab is selected. `daemonResolvesCwd` (a
    /// terminal opened from the docked agent chat) sends only an explicit
    /// `cwd` and lets the daemon's resolver pick the rest
    /// (NEW-TERMINAL-INHERITS-CWD).
    func newTerminalTab(cwd: String? = nil, typing text: String? = nil, typingAhead page: String? = nil, keep: Bool? = nil,
                        fromSelectedTab: Bool = false, daemonResolvesCwd: Bool = false,
                        then: (@MainActor (SurfaceID) -> Void)? = nil) {
        let handle = pane.handle
        // From an agent tab, the agent's cwd (#16620), asked when the tab is made.
        let agent = cwd == nil && fromSelectedTab && !daemonResolvesCwd ? selectedAgentView : nil
        let cwd = daemonResolvesCwd ? cwd : cwd ?? selectedTab?.cwd
        let workspace = services.workspaceKey(of: pane)
        guard let connection = daemon.connection else { return }
        let intent = self.workspace?.beginFocusIntent()
        services.registry.track(Task {
            do {
                var start = cwd
                if let agent, let agentCwd = await agent.workingContext()?.cwd, WorkingURL.isDirectory(agentCwd) { start = agentCwd }
                let created = try await connection.newTab(in: handle, options: SpawnOptions(cwd: start, workspace: workspace, keep: keep)); BenchSpans.mark("daemon.newTab.returned")
                if let text { try await connection.send(created.surface, text: text) }
                if let page {
                    try await services.newTabTypeAhead.drain(page) { try await connection.send(created.surface, text: $0) }
                }
                selectWhenReported(surface: created.surface)
                self.workspace?.expectFocus(on: created.surface, generation: intent)
                then?(created.surface)
                return nil
            } catch {
                daemon.logger.error("new-tab failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("new-tab", error)
            }
        })
    }

    /// New browser tab in this pane (`PaneBrowserTabOpener`), selected and
    /// focused when it lands unless `background`. False when refused.
    @discardableResult
    func newBrowserTab(url: URL? = nil, engine requested: String? = nil, inherited: String? = nil,
                       adopting child: (any BrowserTab)? = nil, background: Bool = false, profile: String? = nil,
                       notice: String? = nil, opener: SurfaceID? = nil, then: (@MainActor (SurfaceID) -> Void)? = nil) -> Bool {
        PaneBrowserTabOpener(controller: self).open(url: url, engine: requested, inherited: inherited, adopting: child, background: background,
                                                    profile: profile, notice: notice, opener: opener, then: then)
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
            if BenchSpans.measure("closeLocalTab", { services.closeLocalTab(id.rawValue) }) { continue }
            if services.madeAgentTabs?.closeWhenCreated(id.rawValue, close: { [weak self] real in self?.close([StripTabID(real)]) }) == true { continue }
            guard let tab = tab(id) else { continue }
            pendingClosed.insert(tab.id)
            surfaces.append(tab.surface)
            commands.append(daemon.closeCommand(for: tab))
            // Its terminal's only view closes: that session may end it.
            if tab.kind == .remoteTerminal { services.remoteTerminals.viewClosed(tab) }
        }
        BenchSpans.measure("pane.apply") { apply(snapshot()) }
        guard !commands.isEmpty else { return }
        let keys = Set(ids.map(\.rawValue))
        let runs = daemon.closeRuns(surfaces: surfaces, commands: commands.map { ($0.label, $0.run) })
        let userClose = CloseUndoToasts.isUserClose // a refused user close shows RefusedCloseNotice
        services.registry.track(Task {
            let (failed, unknown, codes) = await daemon.runReportingOutcomes(runs)
            if failed, userClose { RefusedCloseNotice(services: services).show(codes: codes, in: view.window) }
            // A close that missed its deadline under daemon load usually still
            // lands: keep the tabs hidden until a snapshot ordered after the
            // closes says which ones remain, instead of flashing them back.
            if unknown { await daemon.store.refresh() }
            pendingClosed.subtract(keys)
            for key in keys { services.cache.release(key) }
            if failed || unknown { resyncStrip() }
            return failed ? "close failed (see the app log)" : nil
        })
    }

    /// Moves a tab into `target` at `index` (display order), optimistic.
    func move(_ id: StripTabID, toPane target: PaneController, index: Int) {
        guard let tab = tab(id) else { return }
        let index = StripOrder.paneIndex(forDisplayIndex: index, moving: id, in: target) // `index` is a display index
        // Focus follows only a move this client's user started (CLI and
        // agents never change this client's focus unless they ask).
        if target !== self, ActionRunScope.viewChangeAllowed() { workspace?.focus.followMovedTab(tab.id, from: paneKey) }
        TabMoves.move(tab, to: target.pane, index: index, services: services) { [weak self, weak target] ok in
            guard !ok else { return StripOrder.settle([self, target]) }
            self?.resyncStrip()
            target?.resyncStrip()
            self?.view.stripView.restoreDetachedTab(id)
        }
    }

    func setPinned(_ id: StripTabID, pinned: Bool) {
        guard let tab = tab(id) else { return }
        let surface = tab.surface
        // `tab.pin`/`tab.unpin` on a daemon with state resources.
        let resource = daemon.store.servesStateResources ? tab.resourceID : nil
        guard resource != nil || daemon.supports(DaemonCapabilities.shared.tabMetadata) else {
            services.registry.refuse(daemon.missingCapabilityMessage(DaemonCapabilities.shared.tabMetadata))
            return
        }
        services.registry.track(Task {
            let ok = await daemon.intend("set-tab-pinned", .setTabPinned(surface: surface, pinned: pinned)) { connection in
                if let resource { return try await connection.state.setTabPinned(resource, pinned) }
                _ = try await connection.setTabPinned(surface, pinned)
            }
            if !ok { resyncStrip() }
            return ok ? nil : "set-tab-pinned failed (see the app log)"
        })
    }

    func rename(_ id: StripTabID) {
        guard let tab = tab(id), let window = view.window else { return }
        RenamePrompt.run(title: Strings.renameTabTitle, initial: tab.displayTitle, in: window) { [weak self] name in
            self?.commitRename(id, name: name)
        }
    }

    func commitRename(_ id: StripTabID, name: String) {
        guard let surface = tab(id)?.surface else { return }
        Task { [daemon] in
            await daemon.intend("rename-surface", .renameTab(surface: surface, name: name)) { connection in
                try await connection.renameTab(surface, to: name)
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
                // Hibernation discards a page; a terminal has none.
                let entries = ContextMenuCatalog.shared.entries(for: .tab, removing: ["hibernateTab", "wakeTab"])
                return registry.makeContextMenu(for: .tab, target: target, entries: entries)
            }
            // A browser tab offers the engine it is not on.
            let other: ActionID = tab.browserEngine == BrowserEngineTag.cef.rawValue ? "browser.openInChromium" : "browser.openInWebKit"
            // Terminal themes and keep-running do not apply to a page.
            let entries = ContextMenuCatalog.shared.entries(for: .tab, removing: [other, "terminal.setTheme", "terminal.clearTheme", "terminal.keep"])
            return registry.makeContextMenu(for: .tab, target: target, entries: entries, implied: .browserFocused)
        case .group(let group), .savedGroup(let group):
            let saved = daemon.store.savedTabGroups.contains { $0.openGroup?.rawValue == group.rawValue }
            return registry.makeContextMenu(for: .tabGroup, target: ActionTargetRef(kind: .tabGroup, id: group.rawValue),
                                            entries: TabGroupPinMenu.entries(saved: saved))
        case .emptyStrip:
            let entries = ContextMenuCatalog.shared.entries(for: .newTab) + [.separator] + ContextMenuCatalog.shared.entries(for: .pane)
            return registry.makeContextMenu(for: .pane, target: ActionTargetRef(kind: .pane, id: paneKey), entries: entries)
        case .newTabButton:
            // The engine menu predicts a Chromium tab (ChromiumWarmup).
            services.chromiumWarmup.chromiumLikely(.newTabMenu)
            return registry.makeContextMenu(for: .newTab, target: ActionTargetRef(kind: .pane, id: paneKey))
        }
    }
}
