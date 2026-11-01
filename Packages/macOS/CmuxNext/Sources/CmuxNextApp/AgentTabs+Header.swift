import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon

/// The chat header and right-click menu (``AgentChatTabActions``), its toggling quick actions
/// (``AgentChatSplitToggles``), the header's state, pushed when it changes (``AgentChatHeaderWatch``),
/// and the side pane New side chat and `/btw` open in (``AgentSidePanes``).
extension AgentTabStore {
    func wireHeader(_ model: AgentPaneModel, key provisional: String) {
        let actions = AgentChatTabActions(tab: { [weak self] in self?.resolve(provisional) ?? provisional },
                                          registry: { [weak self] in self?.actionRegistry }, files: { [weak self] in self?.openFiles?(self?.resolve(provisional) ?? provisional, $0, $1) }, hidden: { [weak self] in CloudMove.hiddenMenuItems(self?.lookup(self?.resolve(provisional) ?? provisional)?.record) }, local: { [weak self] in self.flatMap { $0.gitLink?($0.resolve(provisional)) }?.isLocal == true }, openTool: { [weak self] kind, cwd in guard let self else { return false }; return openTool?(resolve(provisional), kind, cwd) ?? false })
        let toggles = AgentChatSplitToggles(), pullRequest = AgentChatPullRequest()
        let watch = AgentChatHeaderWatch(state: { [weak self] in
            guard let self else { return AgentPaneHeaderState() }
            let chat = resolve(provisional)
            return toggles.headerState(chat: chat, store: lookup(chat)?.store, pullRequest: gitLink?(chat)?.isLocal == true ? pullRequest : nil)
        }, push: { [weak self] state in
            guard let view = self?.existingView(provisional) else { return }
            AgentPaneHeaderState.push(state, to: view)
        })
        // Watching from the wiring on: a tab rekeyed after the page's first read is wired again,
        // and its new watch must push without waiting for another read.
        watch.read()
        // The page names the chat's folder once its session summary came; until then (and for a
        // split beside another split) the chat's exact folder from here (terminalFolder).
        model.header = AgentPaneHeaderHooks(run: { [weak self] id, cwd in
            let chat = self?.resolve(provisional) ?? provisional
            toggles.open(id, cwd: cwd ?? self?.terminalFolder(of: chat), chat: chat, store: self?.lookup(chat)?.store, actions: actions)
        }, toggle: { [weak self] id, cwd in
            let chat = self?.resolve(provisional) ?? provisional
            toggles.toggle(id, cwd: cwd ?? self?.terminalFolder(of: chat), chat: chat, store: self?.lookup(chat)?.store, actions: actions)
        }, tabState: {
            // The page reads the state when a chat opens; its changes are pushed.
            watch.read()
        }, openSide: { [weak self] chat, fork in // the tracker (AgentSidePanes) asks RightColumnPlacement; the app opens there
            guard let self else { return }; AgentSidePanes.chat(chat).open(fork, chat: resolve(provisional), hooks: .init(pane: { [weak self] in self?.locate(self?.resolve($0) ?? $0).map { "\(ObjectIdentifier($0.daemon).hashValue):\($0.pane.rawValue)" } }, column: { [weak self] in self?.rightColumn(self?.resolve($0) ?? $0) ?? .init() }) { [weak self] _, _, created, finished in // openOnRight decides again in its turn (RightColumnTurns)
                self?.openOnRight(of: provisional, open: { [weak self] pane, daemon in guard let self else { throw CancellationError() }; return try open(in: pane, of: daemon, session: fork) }, created: { key, _ in created(key) }, finished: { _ in finished() }) ?? false })
        }, openRight: { [weak self] session in guard let self else { return false }; return openRight?(resolve(provisional), session) ?? false
        }, openTab: { [weak self] session, destination in self?.openFork(session, at: destination, beside: provisional) ?? false }, openSubagent: { [weak self] in self?.openSubagent($1, of: $0, focus: $2, beside: provisional) ?? false }, showsSubagent: { [weak self] title in guard let self else { return }; SubagentTabTitles.shared.show(title, inTab: resolve(provisional)) }, openProcess: { [weak self] viewer in guard let self else { return false }; return openProcess?(resolve(provisional), viewer) ?? false }, newChat: { [weak self] in self?.openNewTabColumn(beside: provisional, cwd: $0, split: false) ?? false }, sideTabs: { [weak self] in
            guard let self else { return nil }
            let chat = resolve(provisional)
            return toggles.sideTabs(chat: chat, store: lookup(chat)?.store, actions: actions) { [weak self] in
                self?.openNewTabColumn(beside: provisional) ?? false
            }
        }, preview: { [weak self] url, toggle in
            let chat = self?.resolve(provisional) ?? provisional
            let store = self?.lookup(chat)?.store, id = AgentPaneModel.previewAction
            if toggle { toggles.toggle(id, cwd: nil, url: url, chat: chat, store: store, actions: actions) }
            else { toggles.open(id, cwd: nil, url: url, chat: chat, store: store, actions: actions) }
        }, saveQuickActions: { [weak self] list in
            await self?.customization.saveQuickActions(list) ?? false
        }, moveToFloatingChat: { [weak self] session in actions.moveToFloatingChat(session, via: self?.moveToFloatingChat) }, refreshPullRequest: pullRequest.askAgain, showSession: { [weak self] session in guard let self, let shown = tab(showing: session, host: lookup(resolve(provisional))?.record.host) else { return false }; _ = actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: shown), origin: .user)); return true }, isFamily: { [weak self] session, chat in self?.turns.isFamily(session, of: chat) ?? false }, moveTargets: { [weak self] in
            self?.machineTargets() ?? []
        }, moveToMachine: { [weak self] machine, session in
            guard let self else { return false }
            // Bound to the chat whose menu the page opened: a tab that shows another chat by now
            // (the person switched before this was handled) moves nothing.
            let tab = self.resolve(provisional)
            guard AgentPaneMoveTarget.tabStillShows(self.session(of: tab), requested: session) else { return false }
            return self.moveAgentToMachine(tab, machine)
        }, showsChat: { [weak self] session in
            guard let self else { return false }
            return AgentPaneMoveTarget.tabStillShows(self.session(of: self.resolve(provisional)), requested: session)
        }) // a chat streams in one tab: an opened session's tab (on the chat's acpmux host, a Chief chat's `chief:<id>`) is shown; a chat opens only its family (startedBy)
        // Changes with the chat's turn (D1, D2): the diff beside the chat offers it as Last turn.
        model.header?.diffTurn = { [weak self] cwd, turn, toggle in
            let chat = self?.resolve(provisional) ?? provisional
            let store = self?.lookup(chat)?.store, id = AgentChatSplitToggles.changes, extra = DiffTurnArgument.arguments(turn)
            if toggle { toggles.toggle(id, cwd: cwd, extra: extra, chat: chat, store: store, actions: actions) }
            else { toggles.open(id, cwd: cwd, extra: extra, chat: chat, store: store, actions: actions) }
        }
        model.chatMenuItems = actions.menuItems
        model.onSearchWeb = actions.searchWeb
    }

    /// [+] New tab's column: a New Tab page in the chat's folder (or `cwd`, New Chat Here), moved to
    /// a new split on its right unless not `split`. The page's choices
    /// replace it in whichever pane it is in then. Returns whether the page was started.
    private func openNewTabColumn(beside provisional: String, cwd: String? = nil, split: Bool = true) -> Bool {
        let chat = resolve(provisional)
        // The page opens on the chat's machine: that machine's folders, never this Mac's (cx-k21v).
        guard let newTab = firstPageNewTab?(cwd ?? lookup(chat)?.store.tab(id: chat)?.cwd, chat, nil) else { return false }
        return openBeside(provisional, split: split) { pane, daemon in try self.open(in: pane, of: daemon, newTab: newTab) }
    }

    private func openSubagent(_ agent: String, of session: String, focus: Bool, beside provisional: String) -> Bool { // the tracker (AgentSubagentPanes) decides; the app opens and moves the tab
        let source = resolve(provisional) // one tracker per source chat (AgentSubagentPanes.chat)
        return AgentSubagentPanes.chat(session, source: source).open(agent, focus: focus, chat: provisional, hooks: .init(isOpen: { [weak self] key in self?.subagentTabIsBeside(source, key) ?? false }, focus: { [weak self] key, script in _ = self?.actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: self?.resolve(key) ?? key), arguments: script ? ["focus": .bool(true)] : [:], origin: script ? .script : .user)) },
            // An unfocused tab in the right column is selected there (shown, focus stays); in the chat's own pane it waits in the strip.
            // openOnRight decides again in its turn (RightColumnTurns): the decision that placed it is the one passed to created.
            place: { [weak self] chat, _, created, finished in self?.openOnRight(of: chat, origin: focus ? .user : .script, open: { [weak self] pane, daemon in guard let self else { throw CancellationError() }; return try open(in: pane, of: daemon, session: session) },
                created: { [weak self] key, decision in created(key); SubagentTabTitles.shared.bind(agent, of: session, toTab: key) { [weak self] in self?.locate($0) != nil }; self?.revealTurn(AgentSubagentPanes.reveal(agent), in: key); if case .tab(.some) = decision, !focus { self?.selectInPane(key) } }, finished: finished) ?? false },
            column: { [weak self] in self?.rightColumn(self?.resolve($0) ?? $0) ?? .init() }, again: { [weak self] request in _ = self?.openSubagent(request.agent, of: session, focus: request.focus, beside: request.chat) })) }

    private func subagentTabIsBeside(_ source: String, _ candidate: String) -> Bool { // AgentSubagentPanes.isBeside
        let at = { (found: (pane: PaneID, daemon: DaemonService)?) in found.map { (pane: $0.pane, owner: ObjectIdentifier($0.daemon)) } }
        return AgentSubagentPanes.isBeside(source: at(locate(source)), candidate: at(locate(resolve(candidate)))) { rightColumn(source).panes.map { at(locatePane(source, $0)) } }
    }
    /// What chat tab `provisional` opens on its right, in its turn beside the chat (``RightColumnTurns``,
    /// with every other open there): it decides its place from the column as it is then (``RightColumnPlacement``), and
    /// `created` hears the new tab with that decision. `finished` (or a refusal) ends the turn. An open asked for while
    /// another is still moving into place waits and answers true.
    @discardableResult
    func openOnRight(of provisional: String, origin: ActionOrigin = .user, open: @escaping (PaneID, DaemonService) throws -> AgentTabPending,
                     created: (@MainActor (_ key: String, _ decision: RightColumnPlacement.Decision<String>) -> Void)? = nil,
                     finished: (@MainActor (_ moved: Bool) -> Void)? = nil) -> Bool {
        var opened = true
        var ran = true // the turn ran in this call (false once it waits for another open)
        let now = serially(resolve(provisional)) { [weak self] done in
            guard let self else { finished?(false); return done() }
            let decision = RightColumnPlacement.decide(rightColumn(resolve(provisional)))
            // A created hook is always passed, so openBeside and main pane layout call `finished` on every path once they opened.
            opened = place(decision, of: provisional, origin: origin, open: open, created: { key in created?(key, decision) },
                           finished: { moved in done(); finished?(moved) })
            guard !opened else { return }
            done()
            // Its caller already heard true (it waited its turn), so it hears the refusal here: else the
            // tracker that asked stays "opening" (review of the #28044 carry at 1eb458cf).
            if !ran { finished?(false) }
        }
        ran = false
        return now ? opened : true
    }

    /// ``openOnRight(of:origin:open:created:finished:)``'s open in its turn, where `decision` puts it: a split right of the
    /// chat, a split below the right column's one pane, or a tab in a pane (nil: the chat's own). A chat that is its
    /// screen's main pane with nothing on its right yet makes that column by main pane layout's rule (``openInMainPane``);
    /// once its strip column is there, it is the chat's right side and the same lower split applies.
    private func place(_ decision: RightColumnPlacement.Decision<String>, of provisional: String, origin: ActionOrigin, open: (PaneID, DaemonService) throws -> AgentTabPending, created: @escaping @MainActor (String) -> Void, finished: @escaping @MainActor (_ moved: Bool) -> Void) -> Bool {
        // Nothing on the right (a split right, or a chat too narrow to split: #27789's review at 84718cf2): main pane layout decides first.
        let rightIsEmpty = switch decision { case .splitRight, .tab(nil): true; case .splitBelow, .tab(.some): false }
        if rightIsEmpty, let placed = openInMainPane(resolve(provisional), origin == .user, open, created, finished) { return placed }
        switch decision {
        case .splitRight: return openBeside(provisional, origin: origin, open: open, created: created, finished: finished)
        case .splitBelow(let pane):
            return openBeside(provisional, in: pane, direction: "down", origin: origin, open: open, created: created, finished: finished)
        case .tab(let pane): return openBeside(provisional, in: pane, split: false, origin: origin, open: open, created: created, finished: finished)
        }
    }

    /// A tab in chat tab `provisional`'s pane (or right-column pane `paneKey`), then moved to a new split on its `direction` side when `split`; else a tab there, focused when `created` is set.
    /// A split asked for chat `main` when that chat is its screen's main pane (``openInMainPane``) is a tab in the column on its right instead.
    @discardableResult
    func openBeside(_ provisional: String, in paneKey: String? = nil, split: Bool = true, direction: String = "right", origin: ActionOrigin = .user, main: String? = nil, open: (PaneID, DaemonService) throws -> AgentTabPending, created: (@MainActor (String) -> Void)? = nil, finished: (@MainActor (_ moved: Bool) -> Void)? = nil) -> Bool {
        if split, let main, let placed = openInMainPane(resolve(main), origin == .user, open, created, finished) { return placed }
        let located = if let paneKey { locatePane(resolve(provisional), paneKey) } else { locate(resolve(provisional)) }
        guard let (pane, daemon) = located, let pending = try? open(pane, daemon) else { return false }
        guard split || created != nil else { return true }
        // task-owner: one tab creation, then one move (or, not `split`, one focus) of that tab
        Task { [weak self] in
            guard let tab = try? await pending.value(), let self, await TabMirror.reaches(tab.key, in: locate) else { finished?(false); return }; created?(tab.key)
            // An unfocused (script) tab open, a subagent's in the right column's lower pane, leaves focus where it is.
            guard split else { if origin == .user { _ = actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.key), origin: origin)) }; finished?(false); return }
            _ = actionRegistry?.perform("tab.moveToNewSplit", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.key), arguments: ["direction": .string(direction), "keep_focus": .bool(origin == .script)], origin: origin)) // script: an unfocused subagent open
            if let finished { finished(await TabMirror.reaches(tab.key, in: { [weak self] in self?.locate($0).flatMap { $0.pane != pane ? $0 : nil } })) } // stacking waits for the move
        }
        return true
    }
}
