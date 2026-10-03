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
            close([id])
        case .closeOthers(let keep):
            close(stripModel.orderedTabs.filter { $0.id != keep && !$0.isPinned }.map(\.id))
        case .closeToRight(let id):
            let ids = orderedIDs
            guard let index = ids.firstIndex(of: id) else { return }
            close(Array(ids[(index + 1)...]))
        case .reorder(let id, _, let to):
            StripOrder.reorder(id, to: to, in: self)
        case .newTab:
            StripNewTab.request(pane: paneKey) { _ = services.registry.perform($0, invocation: $1) }
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
        case .trailingButton(let id):
            services.tabBarButtons.perform(id, paneKey: paneKey)
        case .focusLocation:
            let window = services.windowController(showing: self)
            StripLocation.request(pane: paneKey, isFocused: window?.focus.state.pane == paneKey,
                                  focus: { window?.focus.send(.focusPane(paneKey, source: .intent)) },
                                  perform: { _ = services.registry.perform($0, invocation: $1) })
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
        guard let workspace else {
            guard ActionRunScope.viewChangeAllowed() else { return }
            return applySelection(id)
        }
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
    /// `then` runs once the new tab is selected.
    func newTerminalTab(cwd: String? = nil, typing text: String? = nil, keep: Bool? = nil, fromSelectedTab: Bool = false,
                        then: (@MainActor (SurfaceID) -> Void)? = nil) {
        let handle = pane.handle
        // From an agent tab, the agent's cwd (#16620), asked when the tab is made.
        let agent = cwd == nil && fromSelectedTab ? selectedAgentView : nil
        let cwd = cwd ?? selectedTab?.cwd
        let workspace = services.workspaceKey(of: pane)
        guard let connection = daemon.connection else { return }
        let intent = self.workspace?.beginFocusIntent()
        services.registry.track(Task {
            do {
                var start = cwd
                if let agent, let agentCwd = await agent.workingContext()?.cwd, WorkingURL.isDirectory(agentCwd) { start = agentCwd }
                let created = try await connection.newTab(in: handle, options: SpawnOptions(cwd: start, workspace: workspace, keep: keep))
                if let text { try await connection.send(created.surface, text: text) }
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

    /// New browser tab: daemon-owned when supported, on the engine
    /// `BrowserTabService.resolve` picks (an explicit engine, else
    /// `browser.defaultEngine`, Chromium, with the WebKit fallback), else
    /// session-local. The new tab is selected and focused when it lands; a
    /// blank tab focuses its address bar so the user can type a URL.
    /// `inherited` is a reopened or duplicated tab's engine or a popup
    /// opener's (falls back instead of refusing). `adopting` is a popup page
    /// the engine already created (`BrowserPageRequests`). `background` (a
    /// page's Cmd-click) creates the tab without selecting it. `profile` is
    /// an explicit browser profile (else the workspace's, the room's or
    /// `default`); `notice` shows on the new page; `then` runs with the new
    /// surface once the daemon made the tab.
    func newBrowserTab(url: URL? = nil, engine requested: String? = nil, inherited: String? = nil,
                       adopting child: (any BrowserTab)? = nil, background: Bool = false, profile: String? = nil,
                       notice: String? = nil, then: (@MainActor (SurfaceID) -> Void)? = nil) {
        let browserTabs = services.cache.browserTabs!
        if browserTabs.isAvailable() {
            var choice: BrowserEngineChoice
            switch browserTabs.resolve(requested: requested, inherited: inherited) {
            case .refuse(let reason): return services.registry.refuse(BrowserTabService.message(reason))
            case .open(let resolved): choice = resolved
            }
            if child != nil { choice = BrowserPageRequests.choice(adopting: child, inherited: inherited, browserTabs: browserTabs) }
            let pageRequests = services.cache.pageRequests
            let newTabAddress = services.newTabAddress(for: choice)
            let handle = pane.handle
            let intent = background ? nil : workspace?.beginFocusIntent()
            services.registry.track(Task {
                do {
                    // A new tab the user asked for opens the New Tab page; an
                    // adopted page (popup, extension tab) keeps its own.
                    let address = url?.absoluteString ?? (child == nil ? newTabAddress : BrowserNewTabPage.blankURL)
                    let surface = try await browserTabs.open(choice, in: handle, url: address, profile: profile, notice: notice)
                    if let child { pageRequests.adopt(child, surface: surface) }
                    then?(surface)
                    guard !background else { return nil }
                    selectWhenReported(surface: surface)
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
            if services.closeLocalTab(id.rawValue) { continue }
            guard let tab = tab(id) else { continue }
            pendingClosed.insert(tab.id)
            surfaces.append(tab.surface)
            commands.append(daemon.closeCommand(for: tab))
            // Its terminal's only view closes: that session may end it.
            if tab.kind == .remoteTerminal { services.remoteTerminals.viewClosed(tab) }
        }
        apply(snapshot())
        guard !commands.isEmpty else { return }
        let keys = Set(ids.map(\.rawValue))
        let runs = surfaces.count > 1 && daemon.supports(DaemonCapabilities.shared.batchClose)
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
            return registry.makeContextMenu(for: .tabGroup, target: ActionTargetRef(kind: .tabGroup, id: group.rawValue))
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
