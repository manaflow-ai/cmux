import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextTabs
import CmuxNextFocus
import CmuxNextSignposts
import CmuxNextWakeups

// Tab strip intents -> daemon commands. Local-only state (selection,
// session browser tabs) changes in place; everything else is one command
// shown at once through a store intent where the store has one.
extension PaneController {
    func handle(_ intent: TabStripIntent) {
        switch intent {
        case .select(let id): select(id)
        case .close(let id, _): CloseUndoToasts.close(in: self, [id])
        case .closeOthers(let keep): CloseUndoToasts.close(in: self, stripModel.closedByCloseOthers(keeping: keep))
        // Pinned tabs after `id` stay, as in Chrome.
        case .closeToRight(let id): CloseUndoToasts.close(in: self, stripModel.closedByCloseToRight(of: id))
        case .reorder(let id, _, let to): StripOrder.reorder(id, to: to, in: self)
        case .reorderTabs(let order): StripOrder.reorder(toward: order, in: self)
        case .newTab(_, let opensWorkspace, let sameKind):
            StripNewTab.request(pane: paneKey, opensWorkspace: opensWorkspace, sameKind: sameKind) {
                _ = services.registry.perform($0, invocation: $1)
            }
        case .pin(let id), .unpin(let id): setPinned(id, pinned: { if case .pin = intent { true } else { false } }())
        case .rename(let id): rename(id)
        case .renameCommitted(let id, let name): commitRename(id, name: name)
        case .duplicate(let id): newTerminalTab(cwd: tab(id)?.cwd)
        // The speaker click runs Mute Tab, the menu's, palette's and CLI's one path.
        case .toggleAudioMute(let id):
            _ = services.registry.perform(BrowserTabAudio.toggleActionID,
                                          invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id.rawValue), origin: .user))
        case .moveToNewSplit(let id, let direction):
            guard let tab = tab(id) else { return }
            TabMoves.toNewSplit(tab, pane: pane, edge: direction == .right ? .right : .bottom, services: services)
        case .moveToNewColumn(let id):
            guard let tab = tab(id) else { return }
            TabMoves.toNewColumn(tab, anchor: pane, services: services)
        case .dragBegan(let start): services.dragSession.begin(start, from: self)
        case .groupDragBegan(let start): services.dragSession.beginGroup(start, from: self)
        case .toggleGroupCollapsed, .moveGroup, .addToGroup, .removeFromGroup, .group, .createGroup:
            handleGroup(intent)
        }
    }

    /// A user selection (strip click, shortcut, palette, CLI): goes through
    /// the focus coordinator, which selects and focuses (`applySelection`).
    /// An action run without view-change permission selects nothing.
    func select(_ id: StripTabID, source: FocusEvent.Source = .intent) {
        // Only a switch that will show is timed: the focus coordinator refuses a run without view-change
        // permission, and a suspended pane shows nothing until `resume`.
        if stripModel.selectedID != id, !isSuspended, ActionRunScope.viewChangeAllowed() { DebugTabSwitch.began(self, to: id, keyInput: services.keyRouter.keyInput) }
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
        DebugTabSwitch.mark(self, "focus")
        BenchSpans.measure("switch.select") {
            state.selection.select(id.rawValue, in: paneKey)
            setStripSelection(id)
        }
        DebugTabSwitch.mark(self, "strip")
        BenchSpans.measure("switch.showSelected") { presentSelection() }
        DebugTabSwitch.mark(self, "present")
        BenchSpans.measure("switch.remap") { remapViewedTab() }
        BenchSpans.measure("switch.record") { services.windows.recordSaver.stateDidChange(state) }
        DebugTabSwitch.mark(self, "record")
        DebugTabSwitch.shown(self, in: view.window)
    }

    /// Selects the visible neighbor `offset` tabs away, wrapping; a tab
    /// inside a collapsed group is skipped, as the strip does not show it.
    func selectAdjacent(_ offset: Int) {
        guard let next = stripModel.adjacentVisibleTab(from: stripModel.selectedID, offset: offset) else { return }
        select(next)
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
        // Nothing opens in Home's dock: without a placement of the caller's, the tab moves beside it.
        let then = then ?? HomeDockOpens.placing(pane, services: services, focus: true, then: nil)
        let handle = pane.handle
        // From an agent tab, the agent's cwd (#16620), asked when the tab is made.
        let agent = cwd == nil && fromSelectedTab && !daemonResolvesCwd ? selectedAgentView : nil
        // A selected agent chat's exact folder at once (NewTerminalStart.folder); the page's own
        // answer above still wins when it comes.
        let cwd = daemonResolvesCwd ? cwd : cwd ?? (fromSelectedTab ? NewTerminalStart.inherited(besides: selectedTab, in: pane, services: services) : nil) ?? selectedTab?.cwd
        // From another machine's terminal (an SSH tab in a mixed pane), a terminal on that machine (cx-2s5t).
        if fromSelectedTab, text == nil, page == nil,
           services.remoteTerminals.openTerminal(besides: selectedTab, in: pane, home: daemon, cwd: cwd) { return }
        let workspace = services.workspaceKey(of: pane)
        guard let connection = daemon.connection else { return }
        let timing = services.cache.createTabs.begin(.terminal, shows: showsNewTabs) // create.tab: from this turn to its first frame
        let intent = self.workspace?.beginFocusIntent()
        // The window's keys wait until the new terminal has the keyboard (cx-wb5.76); a creation
        // that types its own text first keeps the keys where they are.
        let window = self.workspace == nil || text != nil || page != nil ? nil : view.window
        // The PTY starts at the grid this pane's view will fit, so the first frame is final (NewTerminalGrid).
        let size = newTerminalSize
        let command = NewTerminalTabCommand(pane: handle, options: SpawnOptions(cwd: cwd, size: size, workspace: workspace, keep: keep))
        if text == nil, page == nil, command.isOptimistic(on: daemon) {
            return newTerminalTabNow(command, agent: agent, intent: intent, window: window, timing: timing, then: then)
        }
        let keys = services.keyRouter.creationInputCoordinator.begin(in: window, generation: intent)
        // main-hop-allow: the action's tracked work awaits the daemon connection's actor and the agent page's main-actor context; selection and focus run in its reply's job
        services.registry.track(Task { [services] in
            var landed = false
            defer { services.keyRouter.creationInputCoordinator.resolve(keys, landed: landed, in: window) }
            do {
                var start = cwd
                if let agent, let agentCwd = await agent.workingContext()?.cwd, WorkingURL.isDirectory(agentCwd) { start = agentCwd }
                let created = try await NewTerminalTrace.shared.request(of: timing, surface: \.surface.rawValue) { try await connection.newTab(in: try await daemon.store.daemonTarget(handle), options: SpawnOptions(cwd: start, size: size, workspace: workspace, keep: keep)) }; BenchSpans.mark("daemon.newTab.returned")
                if let text { try await connection.send(created.surface, text: text) }
                if let page {
                    try await services.newTabTypeAhead.drain(page) { try await connection.send(created.surface, text: $0) }
                }
                if let timing { services.cache.createTabs.expect(timing, surface: created.surface.rawValue) } // the tab's once the pane lists it
                selectWhenReported(surface: created.surface)
                self.workspace?.expectFocus(on: created.surface, generation: intent)
                landed = true
                then?(created.surface)
                return nil
            } catch {
                timing?.end(.closed) // no tab was made
                daemon.logger.error("new-tab failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("new-tab", error)
            }
        })
    }

    /// ``newTerminalTab(cwd:typing:typingAhead:keep:fromSelectedTab:daemonResolvesCwd:then:)`` that
    /// waits for nothing (Ctrl-`, ctrl-backtick-instant): the stand-in tab is in the store, selected
    /// and shown in this turn, so it draws in the key's frame; `new-tab` runs behind it, and the
    /// daemon's tab takes its place (``NewTerminalTabCommand``). The keys typed meanwhile go to the
    /// stand-in's terminal as soon as its view has the keyboard: the view sends them to the daemon by
    /// the terminal id this create chose, which queues them for the PTY (cx-wb5.78), so no key waits
    /// for the reply (first-seconds-evidence.md: they waited 250-1600 ms and were sent again late).
    /// A daemon that does not queue such keys, or a create on a stand-in pane (it waits for that pane), keeps them until then.
    private func newTerminalTabNow(_ command: NewTerminalTabCommand, agent: AgentPaneView?, intent: UInt64?, // perf-hot: 10ms new-tab (the terminal stand-in shows in the key's turn)
                                   window: NSWindow?, timing: CreateTabInterval?, then: (@MainActor (SurfaceID) -> Void)?) {
        // task-owner: the selected agent's cwd, read while the stand-in shows (#16620)
        let agentCwd = agent.map { agent in
            // main-hop-allow: the agent page's working context is its main-actor async read; the stand-in already shows
            Task { @MainActor () -> String? in
                guard let cwd = await agent.workingContext()?.cwd, WorkingURL.isDirectory(cwd) else { return nil }
                return cwd
            }
        }
        let pending = BenchSpans.measure("newTerminal.intend") { command.intendNow(on: daemon, cwd: agentCwd) }
        // In the key's turn, before any later key: focus expects the stand-in (so a Cmd-W of it drops the keys typed for
        // it), and its view takes them early, by its terminal id, once it has the keyboard; the daemon's tab then adopts
        // that view (`TabContentCache.adoptStandIn`), as a split's provisional pane keeps its own.
        if let intent { self.workspace?.focus.expect(.tab(pending.tab), generation: intent) }
        let keys = services.keyRouter.creationInputCoordinator.begin(in: window, generation: intent,
                                                                     earlyTab: daemon.queuesCreatingInput(on: command.pane) ? pending.tab : nil, tab: pending.tab)
        if let timing { services.cache.createTabs.expect(timing, tab: pending.tab, standIn: true) } // the stand-in's terminal is the tab's for good
        showStandIn(surface: pending.surface, focus: .content, intent: intent)
        // main-hop-allow: the stand-in shows in this turn; the tracked work awaits the command's main-actor send and selects in its reply's job
        // After the workspace's create before it (a Ctrl-` on a split still in flight names that split's pane once the
        // daemon made it), as Cmd-D, New Column and New Row go (`WorkspaceContentController.pendingCreate`).
        let previous = self.workspace?.pendingCreate
        // main-hop-allow: the stand-in shows in this turn; the tracked work awaits the command's main-actor send and selects in its reply's job
        let work: ActionWork = Task { [services] in
            var landed = false
            defer { services.keyRouter.creationInputCoordinator.resolve(keys, landed: landed, in: window) }
            await previous?.value
            do {
                let created = try await NewTerminalTrace.shared.request(of: timing, surface: \.surface.rawValue) { try await pending.send() }; BenchSpans.mark("daemon.newTab.returned") // create.tab: request_sent, reply
                // The swap moved the selection already (NewTabSuccession); a pane still on the stand-in follows it.
                if stripModel.selectedID?.rawValue == pending.tab { selectWhenReported(surface: created.surface) }
                self.workspace?.expectFocus(on: created.surface, generation: intent)
                landed = true
                then?(created.surface)
                return nil
            } catch is NewTerminalTabCancelled {
                return nil // the person closed the stand-in first
            } catch {
                services.cache.createTabs.released(pending.tab) // the daemon refused it: the stand-in is gone
                daemon.logger.error("new-tab failed: \(String(describing: error), privacy: .public)")
                return .create("new-tab", error)
            }
        }
        self.workspace?.pendingCreate = work
        // A refusal never vanishes: the stand-in rolls back and the refusal shows where refusals show (rule a).
        services.registry.trackRollingBack("newSurface", work)
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
    /// The tabs leave the visible state now through one close intent on the
    /// store (`DaemonStore.intendClose`), the same log as the creates: they stay
    /// out until the daemon's records drop them, and come back only when the
    /// daemon refused the close (tab-spam-race).
    func close(_ ids: [StripTabID]) {
        guard let prepared = prepareClose(ids) else { return }
        let daemon = daemon
        let runs = daemon.closeRuns(surfaces: prepared.surfaces, commands: prepared.commands)
        let userClose = CloseUndoToasts.isUserClose // a refused user close shows RefusedCloseNotice
        // main-hop-allow: the tabs left the strip in this turn (the close intent); the tracked work awaits the daemon service's main-actor close runs
        services.registry.track(Task { [services] in
            let outcome = await daemon.runReportingOutcomes(runs)
            if outcome.failed, userClose { RefusedCloseNotice(services: services).show(codes: outcome.codes, in: view.window) }
            await prepared.finish(outcome.failed, outcome.unknown)
            return outcome.failed ? "close failed (see the app log)" : nil
        })
    }

    /// The local half of a close of `ids`: app-local tabs and tabs still being
    /// created go now; the daemon tabs leave the visible state through one
    /// close intent, and the pane starts leaving when its last tab goes. Nil
    /// when no daemon tab is left to close. The caller sends the returned
    /// commands (alone, or with other panes' in one batch, `PaneController.close(_:)`)
    /// and then calls its `finish`.
    func prepareClose(_ ids: [StripTabID]) -> PreparedTabClose? {
        guard !ids.isEmpty else { return nil }
        var commands: [DaemonService.CloseRun] = []
        var surfaces: [SurfaceID] = []
        var keys: [String] = []
        for id in ids {
            services.cache.createTabs.released(id.rawValue) // closed before its first frame: create.tab ends as closed
            // Keys held for a creation of this tab (a stand-in its daemon tab adopted included) go with it: a close by
            // mouse or menu never runs them into what has the focus next. A no-op when nothing waits for it.
            services.keyRouter.creationInputCoordinator.drop(tab: id.rawValue, in: view.window)
            if id.rawValue.hasPrefix(LocalBrowserTab.prefix) {
                state?.localBrowserTabs[paneKey].removeAll { $0.id == id.rawValue }
                services.cache.release(id.rawValue)
                continue
            }
            if BenchSpans.measure("closeLocalTab", { services.closeLocalTab(id.rawValue) }) { continue }
            if daemon.cancelCreation(tab: id.rawValue) { services.keyRouter.creationInputCoordinator.drop(tab: id.rawValue, in: view.window); services.keyRouter.newTabInputCoordinator.drop(tab: id.rawValue, in: view.window); continue }
            guard let tab = tab(id) else { continue }
            surfaces.append(tab.surface)
            keys.append(tab.id)
            // Built from the records before the intent takes the tabs out of them.
            let command = daemon.closeCommand(for: tab)
            commands.append((command.label, command.run))
            // Its terminal's only view closes: that session may end it.
            if tab.kind == .remoteTerminal { services.remoteTerminals.viewClosed(tab) }
        }
        let daemon = daemon
        let store = daemon.store
        let transaction = store.intendClose(surfaces)
        BenchSpans.measure("pane.apply") { apply(snapshot()) }
        guard !commands.isEmpty else { return nil }
        // Its last tab closes: the whole pane leaves now, its neighbours springing into its space
        // (close-animation DESIGN.md); the strip has nothing left to animate.
        let paneClose = stripModel.tabs.isEmpty ? showPaneClose() : nil
        return PreparedTabClose(surfaces: surfaces, commands: commands) { [self, services] failed, unknown in
            if let transaction {
                if failed {
                    // The daemon kept some: the records show what it has.
                    store.rejectIntent(transaction)
                } else if unknown {
                    // A close that missed its deadline under daemon load usually still
                    // lands: the tabs stay out until a snapshot ordered after the closes
                    // says which ones remain, instead of flashing them back.
                    store.noteSettledAtNextSnapshot(transaction)
                    await store.refresh()
                } else if let sequence = await daemon.connection?.eventSequence() {
                    // Read-your-writes: the tabs stay out until the store applied the
                    // `tab-closed` events the daemon sent before its reply.
                    store.noteSettled(transaction, at: sequence)
                } else {
                    store.noteSettledAtNextSnapshot(transaction)
                }
            }
            finishPaneClose(paneClose, failed: failed)
            for key in keys { services.cache.release(key) }
            if failed || unknown { resyncStrip() }
        }
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
        guard resource != nil || daemon.supports(DaemonCapability.tabMetadata.rawValue) else {
            services.registry.refuse(daemon.missingCapabilityMessage(DaemonCapability.tabMetadata.rawValue))
            return
        }
        // main-hop-allow: daemon.intend is the store's main-actor intent: the pin shows in its first step, the send and rollback follow
        services.registry.track(Task { [services] in
            let ok = await daemon.intend("set-tab-pinned", .setTabPinned(surface: surface, pinned: pinned)) { connection in
                if let resource { return try await connection.state.setTabPinned(resource, pinned) }
                _ = try await connection.setTabPinned(surface, pinned)
            }
            if !ok { resyncStrip() }
            return withExtendedLifetime(services) { ok ? nil : "set-tab-pinned failed (see the app log)" }
        })
    }

    /// Asks for the tab's new name as a Cmd-Shift-P step that starts from its title; Return runs
    /// Rename Tab with it.
    func rename(_ id: StripTabID) {
        guard let tab = tab(id) else { return }
        services.registry.ask("renameTab", ActionInvocation(target: ActionTargetRef(kind: .tab, id: id.rawValue)),
                              ActionArgumentAsk(argument: "name", initialText: tab.displayTitle))
    }

    func commitRename(_ id: StripTabID, name: String) {
        guard let surface = tab(id)?.surface else { return }
        // main-hop-allow: daemon.intend is the store's main-actor intent: the name shows in its first step, the send and rollback follow
        Task { [daemon] in
            await daemon.intend("rename-surface", .renameTab(surface: surface, name: name)) { connection in
                try await connection.renameTab(surface, to: name)
            }
        }
    }

    // MARK: Context menus

    /// A tab's menu, the same wherever it is opened (its strip, its row in
    /// the sidebar): a browser tab drops what does not apply to a page.
    /// New <Kind> Tab reads as the kind `sameKind` names ("New Browser Tab").
    /// `selectionPins`: the menu is on one of several selected tabs, its rows act on all of them, and Pin pins them (true) or unpins.
    static func tabMenu(_ id: String, tab: TabModel?, keepsTab: Bool, sameKind: NewTabKind, registry: ActionRegistry, selectionPins: Bool? = nil) -> NSMenu {
        let menu = tabMenuEntries(id, tab: tab, keepsTab: keepsTab, registry: registry, arguments: selectionPins == nil ? [:] : ActionInvocation.tabSelectionArguments)
        // It sits in a submenu (More > New).
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(all) }
        if let item = all(menu).first(where: { ActionRegistry.menuRun(of: $0)?.id == "newTab.ofKind" }),
           let title = registry.title(for: sameKind.newActionID) {
            item.title = title
        }
        return selectionPins.map { menu.namingTabSelection(pins: $0) } ?? menu
    }

    private static func tabMenuEntries(_ id: String, tab: TabModel?, keepsTab: Bool, registry: ActionRegistry, arguments: [String: ActionValue]) -> NSMenu {
        let target = ActionTargetRef(kind: .tab, id: id)
        // Home keeps its own tab: no promote entries (TabPromotion).
        let kept = Set(TabPromotion.menuRemovals(keepsTab: keepsTab))
        guard let tab, tab.kind == .browser else {
            // Hibernation discards a page; a terminal has none (Restart only once its shell ended).
            // Reload, Mute and Picture in Picture are a page's rows (Chrome's Reload, Mute Site).
            let pageRows: Set<ActionID> = ["hibernateTab", "wakeTab", "neverHibernateSite", "toggleTabAudioMute", "reloadTab", PictureInPictureHandlers.actionID]
            let entries = ContextMenuCatalog.shared.entries(for: .tab, removing: kept.union(pageRows).union(TabRestart.hiddenMenuItems(tab)).union(CloudMove.hiddenMenuItems(tab)))
            return registry.makeContextMenu(for: .tab, target: target, entries: entries, arguments: arguments)
        }
        // A browser tab offers the engine it is not on.
        let other: ActionID = tab.browserEngine == BrowserEngineTag.cef.rawValue ? "browser.openInChromium" : "browser.openInWebKit"
        // Terminal themes and keep-running do not apply to a page.
        let entries = ContextMenuCatalog.shared.entries(for: .tab, removing: kept.union([other, "terminal.setTheme", "terminal.clearTheme", "terminal.keep", TabRestart.action, CloudMove.action, CloudBringBack.action]))
        return registry.makeContextMenu(for: .tab, target: target, entries: entries, implied: .browserFocused, arguments: arguments)
    }

    func contextMenu(for target: TabContextTarget) -> NSMenu? {
        let registry = services.registry
        switch target {
        case .tab(let id, let selection):
            // Building the menu selects nothing and moves no focus (#24913: the selection's focus
            // move made a Chromium page window key inside the right-click). The rows act on the
            // right-clicked tab, or on the selection it is one of (`AppActionContext.actionTabs`).
            return Self.tabMenu(id.rawValue, tab: tab(id), keepsTab: TabPromotion.staysPut(tab: id.rawValue, in: workspace?.workspace),
                                sameKind: NewTabKind.of(id.rawValue, tab: tab(id), services: services),
                                registry: registry, selectionPins: selection.count > 1 ? stripModel.pinsAll(selection) : nil).themeRows(in: view.themeScope.fullStrength)
        case .group(let group), .savedGroup(let group):
            let saved = daemon.store.savedTabGroups.contains { $0.openGroup?.rawValue == group.rawValue }
            return registry.makeContextMenu(for: .tabGroup, target: ActionTargetRef(kind: .tabGroup, id: group.rawValue),
                                            entries: TabGroupPinMenu.entries(saved: saved)).themeRows(in: view.themeScope.fullStrength)
        case .emptyStrip:
            let entries = ContextMenuCatalog.shared.entries(for: .newTab) + [.separator] + ContextMenuCatalog.shared.entries(for: .pane)
            return registry.makeContextMenu(for: .pane, target: ActionTargetRef(kind: .pane, id: paneKey), entries: entries).themeRows(in: view.themeScope.fullStrength)
        case .newTabButton:
            // The engine menu predicts a Chromium tab (ChromiumWarmup).
            services.chromiumWarmup.chromiumLikely(.newTabMenu)
            return registry.makeContextMenu(for: .newTab, target: ActionTargetRef(kind: .pane, id: paneKey)).themeRows(in: view.themeScope.fullStrength)
        }
    }
}
