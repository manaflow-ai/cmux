import struct CmuxNextLayout.MainPaneLayout
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
                                          registry: { [weak self] in self?.actionRegistry }, files: { [weak self] in self?.openFiles?(self?.resolve(provisional) ?? provisional, $0, $1) }, hidden: { [weak self] in CloudMove.hiddenMenuItems(self?.lookup(self?.resolve(provisional) ?? provisional)?.record) }, local: { [weak self] in self.flatMap { $0.gitLink?($0.resolve(provisional)) }?.isLocal == true })
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
        }, openSide: { [weak self] _, fork in
            _ = self?.openChildBeside(fork, beside: provisional)
        }, openTab: { [weak self] session, destination in self?.openFork(session, at: destination, beside: provisional) ?? false }, openSubagent: { [weak self] in self?.openSubagent($1, of: $0, focus: $2, beside: provisional) ?? false }, openProcess: { [weak self] viewer in guard let self else { return false }; return openProcess?(resolve(provisional), viewer) ?? false }, newChat: { [weak self] in self?.openNewTabColumn(beside: provisional, cwd: $0, split: false) ?? false }, sideTabs: { [weak self] in
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
        }, moveToFloatingChat: { [weak self] session in actions.moveToFloatingChat(session, via: self?.moveToFloatingChat) }, refreshPullRequest: pullRequest.askAgain, showSession: { [weak self] session in
            guard let self, let shown = tab(showing: session, host: lookup(resolve(provisional))?.record.host) else { return false }
            _ = actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: shown), origin: .user))
            return true
        }, isFamily: { [weak self] session, chat in self?.turns.isFamily(session, of: chat) ?? false }) // a chat streams in one tab: an opened session's tab (on the chat's acpmux host, a Chief chat's `chief:<id>`) is shown; a chat opens only its family (startedBy)
        // Changes with the chat's turn (D1, D2): the diff beside the chat offers it as Last turn.
        model.header?.diffTurn = { [weak self] cwd, turn, toggle in
            let chat = self?.resolve(provisional) ?? provisional
            let store = self?.lookup(chat)?.store, id = AgentChatSplitToggles.changes, extra = DiffTurnArgument.arguments(turn)
            if toggle { toggles.toggle(id, cwd: cwd, extra: extra, chat: chat, store: store, actions: actions) }
            else { toggles.open(id, cwd: cwd, extra: extra, chat: chat, store: store, actions: actions) }
        }
        model.header?.openSubagentList = { [weak self] session in
            self?.openSubagent(nil, of: session, focus: true, beside: provisional) ?? false
        }
        model.header?.openSideBackground = { [weak self] _, fork in _ = self?.openChildBeside(fork, beside: provisional, focus: false) }
        model.header?.showSessionBackground = { [weak self] session in self?.showSessionBeside(session, chat: provisional, focus: false) ?? false }
        model.chatMenuItems = actions.menuItems
        model.onSearchWeb = actions.searchWeb
    }

    /// [+] New tab's column: a New Tab page in the chat's folder (or `cwd`, New Chat Here), moved to
    /// a new split on its right unless not `split`. The page's choices
    /// replace it in whichever pane it is in then. Returns whether the page was started.
    private func openNewTabColumn(beside provisional: String, cwd: String? = nil, split: Bool = true) -> Bool {
        let chat = resolve(provisional)
        // The page opens on the chat's machine: that machine's folders, never this Mac's (cx-k21v).
        guard let newTab = firstPageNewTab?(cwd ?? lookup(chat)?.store.tab(id: chat)?.cwd, chat) else { return false }
        return openBeside(provisional, split: split) { pane, daemon in try self.open(in: pane, of: daemon, newTab: newTab) }
    }

    private func openSubagent(_ agent: String?, of session: String, focus: Bool, beside provisional: String) -> Bool {
        let source = subagentSource(provisional)
        let identity = agent.map { "agent:\($0)" } ?? "list"
        let reveal = agent.map(AgentSubagentPanes.reveal) ?? "subagents:list"
        return AgentSubagentPanes.session("\(session):\(source)").open(identity, focus: focus, chat: source, hooks: .init(
            isOpen: { [weak self] key in self?.isBeside(source, self?.resolve(key) ?? key) ?? false },
            focus: { [weak self] key, script in
                _ = self?.actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: self?.resolve(key) ?? key), arguments: script ? ["focus": .bool(true)] : [:], origin: script ? .script : .user))
            }, reveal: { [weak self] key, _ in
                self?.revealTurn(reveal, in: key)
            }, place: { [weak self] anchor, hasSide, created, finished in
                guard let self else { return false }
                return openBeside(hasSide ? anchor : source, split: !hasSide, origin: focus ? .user : .script, main: source,
                    open: { [weak self] pane, daemon in
                        guard let self else { throw CancellationError() }
                        let record = lookup(source)?.record
                        return try open(in: pane, of: daemon, session: session, host: daemon.isLocal ? record?.host : nil)
                    }, created: { [weak self] key in
                        created(key)
                        self?.subagentSources[key] = source
                        self?.revealTurn(reveal, in: key)
                    }, finished: finished)
            }, again: { [weak self] request in
                _ = self?.openSubagent(request.agent == "list" ? nil : String(request.agent.dropFirst(6)), of: session, focus: request.focus, beside: request.chat)
            }))
    }

    func subagentSource(_ tab: String) -> String {
        let tab = resolve(tab)
        guard let source = subagentSources[tab].map(resolve), locate(source) != nil, isBeside(source, tab) else { return tab }
        return source
    }
    /// A tab in chat tab `provisional`'s pane, then moved to a new split on its right when `split`; else a tab there, focused when `created` is set.
    /// A split asked for chat `main` when that chat is its screen's main pane (``openInMainPane``) is a tab in the column on its right instead.
    @discardableResult
    func openBeside(_ provisional: String, split: Bool = true, direction: String = "right", origin: ActionOrigin = .user, main: String? = nil, open: (DaemonPaneID, DaemonService) throws -> AgentTabPending, created: (@MainActor (String) -> Void)? = nil, finished: (@MainActor (_ moved: Bool) -> Void)? = nil) -> Bool {
        if split, let main, let placed = openInMainPane(resolve(main), origin == .user, open, created, finished) { return placed }
        guard let (pane, daemon) = locate(resolve(provisional)), let pending = try? open(pane, daemon) else { return false }
        guard split || created != nil else { return true }
        // task-owner: one tab creation, then one move (or, not `split`, one focus) of that tab
        Task { [weak self] in
            guard let tab = try? await pending.value(), let self, await TabMirror.reaches(tab.key, in: locate) else { finished?(false); return }; created?(tab.key)
            guard split else {
                if origin == .user {
                    _ = actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.key), origin: origin))
                }
                finished?(false)
                return
            }
            _ = actionRegistry?.perform("tab.moveToNewSplit", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.key), arguments: ["direction": .string(direction), "keep_focus": .bool(origin == .script)], origin: origin)) // script: an unfocused subagent open
            if let finished { finished(await TabMirror.reaches(tab.key, in: { [weak self] in self?.locate($0).flatMap { $0.pane != pane ? $0 : nil } })) } // stacking waits for the move
        }
        return true
    }
}

extension AgentTabStore {
    /// Reuse only a tab in this chat's right pane, on its acpmux host. A tab in another
    /// workspace must never pull the person away from the chat they clicked in.
    @MainActor func showSessionBeside(_ session: String, chat: String, host: String? = nil, focus: Bool = true) -> Bool {
        let source = resolve(chat), host = host ?? lookup(resolve(chat))?.record.host ?? localHost
        guard let tab = subagentTabsBeside(source).first(where: {
            $0.record.host == host && self.session(of: $0.key) == session && isBeside(source, resolve($0.key))
        }) else { return false }
        if !focus { return true }
        return actionRegistry?.perform("tab.focus", invocation: .init(target: .init(kind: .tab, id: resolve(tab.key)), origin: .user)) == true
    }

    /// The side-session queue serializes placement; queued re-clicks recheck reuse after the
    /// first tab lands. Keyed by source tab so the same chat in another workspace stays there.
    @discardableResult
    @MainActor func openChildBeside(_ session: String, beside chat: String, host: String? = nil, focus: Bool = true) -> Bool {
        let source = subagentSource(chat), host = host ?? lookup(resolve(chat))?.record.host
        let pane: (String) -> String? = { [weak self] key in
            guard let self, isBeside(resolve(source), resolve(key)), let location = locate(resolve(key)) else { return nil }
            return "\(ObjectIdentifier(location.daemon).hashValue):\(location.pane.rawValue)"
        }
        let place: (String?, @escaping @MainActor (String) -> Void, @escaping @MainActor () -> Void) -> Bool = { [weak self] anchor, created, finished in
            guard let self else { return false }
            if showSessionBeside(session, chat: source, host: host, focus: focus) { finished(); return true }
            let open: (DaemonPaneID, DaemonService) throws -> AgentTabPending = { [weak self] pane, daemon in
                guard let self else { throw CancellationError() }
                let record = lookup(source)?.record
                return try self.open(in: pane, of: daemon, session: session, host: daemon.isLocal || host != record?.host ? host : nil)
            }
            return openBeside(anchor ?? source, split: anchor == nil, origin: focus ? .user : .script, main: source, open: open, created: created, finished: { _ in finished() })
        }
        return AgentSidePanes.chat(source).open(session, chat: source, pane: pane, place: place)
    }
}

extension AppServices {
    @MainActor func subagentSourcePane(of chat: String) -> PaneController? {
        locateTab(chat).flatMap { paneController(for: $0.1) } ?? paneController(showingTab: chat)
    }

    /// Same column order and right-neighbor fallback used by links, including split layouts.
    @MainActor func subagentSidePane(of chat: String) -> PaneController? {
        guard let source = subagentSourcePane(of: chat), let content = source.workspace else { return nil }
        if case .tab(let id) = MainPaneLayout.side(from: source, services: self) { return content.panes[id] }
        let takes: (LayoutPaneID) -> Bool = { content.panes[$0]?.stripModel.showsNewTabButton == true }
        if !source.stripModel.showsNewTabButton, let screen = content.layoutModel.screen(containing: source.layoutPaneID),
           let id = LinkOpenPlacement<LayoutPaneID>.paneRight(of: source.layoutPaneID,
               columns: screen.layout.visualColumns.map(\.root.panes), takesTabs: takes, recency: content.recentPanes) {
            return content.panes[id]
        }
        return PaneHandlers.neighbor(of: source.layoutPaneID, direction: .right, in: content).flatMap { takes($0) ? content.panes[$0] : nil }
    }
}
