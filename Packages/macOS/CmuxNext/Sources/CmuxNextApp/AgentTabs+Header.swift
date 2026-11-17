import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTabs

/// The chat header/menu, quick actions, watched state, and side-pane opens.
extension AgentTabStore {
    func wireHeader(_ model: AgentPaneModel, key provisional: String, machine: String? = nil) {
        let scoped = tabKey(provisional, machine: machine)
        let actions = AgentChatTabActions(tab: { [weak self] in self?.resolve(provisional, machine: scoped.machine) ?? provisional }, machine: scoped.machine.isEmpty ? nil : scoped.machine,
                                          registry: { [weak self] in self?.actionRegistry }, files: { [weak self] in self?.openFiles?(self?.resolve(provisional, machine: scoped.machine) ?? provisional, $0, $1) }, hidden: { [weak self] in guard let self else { return [] }; return CloudMove.hiddenMenuItems(self.record(for: self.resolvedKey(scoped))?.record) }, local: { [weak self] in self?.gitLinkScoped?(self?.resolvedKey(scoped) ?? scoped)?.isLocal == true }, openTool: { [weak self] kind, cwd in guard let self else { return false }; return self.openToolScoped?(self.resolvedKey(scoped), kind, cwd) ?? false })
        let toggles = AgentChatSplitToggles(), pullRequest = AgentChatPullRequest()
        let watch = AgentChatHeaderWatch(state: { [weak self] in
            guard let self else { return AgentPaneHeaderState() }
            let chat = resolve(provisional, machine: scoped.machine)
            return toggles.headerState(chat: chat, store: record(for: resolvedKey(scoped))?.store, pullRequest: gitLinkScoped?(resolvedKey(scoped))?.isLocal == true ? pullRequest : nil)
        }, push: { [weak self] state in
            guard let view = self?.existingView(provisional, machine: scoped.machine) else { return }
            AgentPaneHeaderState.push(state, to: view)
        })
        // Watching from the wiring on: a tab rekeyed after the page's first read is wired again,
        // and its new watch must push without waiting for another read.
        watch.read()
        // The page names the chat's folder once its session summary came; until then (and for a
        // split beside another split) the chat's exact folder from here (terminalFolder).
        model.header = AgentPaneHeaderHooks(run: { [weak self] id, cwd in
            let chat = self?.resolve(provisional, machine: scoped.machine) ?? provisional
            toggles.open(id, cwd: cwd ?? self?.terminalFolder(of: chat, machine: scoped.machine), chat: chat, store: self?.record(for: self?.resolvedKey(scoped) ?? scoped)?.store, actions: actions)
        }, toggle: { [weak self] id, cwd in
            let chat = self?.resolve(provisional, machine: scoped.machine) ?? provisional
            toggles.toggle(id, cwd: cwd ?? self?.terminalFolder(of: chat, machine: scoped.machine), chat: chat, store: self?.record(for: self?.resolvedKey(scoped) ?? scoped)?.store, actions: actions)
        }, tabState: {
            // The page reads the state when a chat opens; its changes are pushed.
            watch.read()
        }, openSide: { [weak self] chat, fork in // the tracker (AgentSidePanes) asks RightColumnPlacement; the app opens there
            guard let self else { return }; AgentSidePanes.chat(chat).open(fork, chat: resolve(provisional, machine: scoped.machine), hooks: .init(pane: { [weak self] in self?.locateScoped(self?.resolvedKey(AgentTabKey(machine: scoped.machine, key: $0)) ?? AgentTabKey(machine: scoped.machine, key: $0)).map { "\(ObjectIdentifier($0.daemon).hashValue):\($0.pane.rawValue)" } }, column: { [weak self] in self?.rightColumnScoped(self?.resolvedKey(AgentTabKey(machine: scoped.machine, key: $0)) ?? AgentTabKey(machine: scoped.machine, key: $0)) ?? .init() }) { [weak self] _, _, created, finished in // openOnRight decides again in its turn (RightColumnTurns)
                self?.openOnRight(of: provisional, machine: scoped.machine, splitRight: AgentSidePanes.chat(chat).takeSplitRight(fork), open: { [weak self] pane, daemon, split in guard let self else { throw CancellationError() }; return try open(in: pane, of: daemon, session: fork, split: split) }, created: { key, _ in created(key) }, finished: { _ in finished() }) ?? false })
        }, openRight: { [weak self] session in guard let self else { return false }; return self.openRightScoped?(self.resolvedKey(scoped), session, nil) ?? false
        }, openTab: { [weak self] session, destination in self?.openFork(session, at: destination, beside: provisional, machine: scoped.machine) ?? false }, openSubagent: { [weak self] in self?.openSubagent($1, of: $0, focus: $2, beside: provisional, machine: scoped.machine) ?? false }, showsSubagent: { [weak self] title, tone, keepingTitle in guard let self else { return }; SubagentTabTitles.shared.show(title, inTab: resolve(provisional, machine: scoped.machine), tone: tone, keepingTitle: keepingTitle) }, showsSubagentFacts: { [weak self] facts in guard let self else { return }; SubagentTabTitles.shared.showFacts(facts, inTab: resolve(provisional, machine: scoped.machine)) }, openProcess: { [weak self] viewer in guard let self else { return false }; return openProcess?(resolve(provisional, machine: scoped.machine), viewer) ?? false }, newChat: { [weak self] in self?.openNewTabColumn(beside: provisional, machine: scoped.machine, cwd: $0, split: false) ?? false }, sideTabs: { [weak self] in
            guard let self else { return nil }
            let chat = resolve(provisional, machine: scoped.machine)
            return toggles.sideTabs(chat: chat, store: record(for: self.resolvedKey(scoped))?.store, actions: actions) { [weak self] in
                self?.openNewTabColumn(beside: provisional, machine: scoped.machine) ?? false
            }
        }, preview: { [weak self] url, toggle in
            let chat = self?.resolve(provisional, machine: scoped.machine) ?? provisional
            let store = self?.record(for: self?.resolvedKey(scoped) ?? scoped)?.store, id = AgentPaneModel.previewAction
            if toggle { toggles.toggle(id, cwd: nil, url: url, chat: chat, store: store, actions: actions) }
            else { toggles.open(id, cwd: nil, url: url, chat: chat, store: store, actions: actions) }
        }, saveQuickActions: { [weak self] list in
            await self?.customization.saveQuickActions(list) ?? false
        }, moveToFloatingChat: { [weak self] session in actions.moveToFloatingChat(session, via: self?.moveToFloatingChat) }, refreshPullRequest: pullRequest.askAgain, showSession: { [weak self] session in guard let self, let shown = tab(showing: session, host: self.record(for: self.resolvedKey(scoped))?.record.host, where: { self.subagentTabIsBeside(self.resolve(provisional, machine: scoped.machine), $0, machine: scoped.machine) }) else { return false }; _ = actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: shown), origin: .user).onMachine(scoped.machine)); return true }, jumpToSession: { [weak self] session in guard let self, let shown = tab(showing: session, host: self.record(for: self.resolvedKey(scoped))?.record.host) else { return false }; _ = actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: shown), origin: .user).onMachine(scoped.machine)); return true }, hasTab: { [weak self] session in guard let self else { return false }; return tab(showing: session, host: self.record(for: self.resolvedKey(scoped))?.record.host) != nil }, isFamily: { [weak self] session, chat in self?.turns.isFamily(session, of: chat) ?? false }, moveTargets: { [weak self] in
            guard let self else { return [] }
            return self.machineTargets(self.resolvedKey(scoped))
        }, moveToMachine: { [weak self] machine, session in
            guard let self else { return false }
            // Bound to the chat whose menu the page opened: a tab that shows another chat by now
            // (the person switched before this was handled) moves nothing.
            let tab = self.resolve(provisional, machine: scoped.machine)
            guard AgentPaneMoveTarget.tabStillShows(self.session(of: tab, machine: scoped.machine), requested: session) else { return false }
            return self.moveAgentToMachine(AgentTabKey(machine: scoped.machine, key: tab), machine)
        }, showsChat: { [weak self] session in
            guard let self else { return false }
            return AgentPaneMoveTarget.tabStillShows(self.session(of: self.resolve(provisional, machine: scoped.machine), machine: scoped.machine), requested: session)
        }) // an opened session's tab (on the chat's acpmux host, a Chief chat's `chief:<id>`) is shown only beside the chat (its pane or right column), never in another workspace; a chat opens only its family (startedBy)
        // Changes with the chat's turn (D1, D2), or the turn's own patch where no git source holds it:
        // the diff beside the chat offers the turn as Last turn, or shows only the patch.
        model.header?.diffOpen = { [weak self] cwd, extra, toggle in
            let chat = self?.resolve(provisional, machine: scoped.machine) ?? provisional
            let store = self?.record(for: self?.resolvedKey(scoped) ?? scoped)?.store, id = AgentChatSplitToggles.changes
            if toggle { toggles.toggle(id, cwd: cwd, extra: extra, chat: chat, store: store, actions: actions) }
            else { toggles.open(id, cwd: cwd, extra: extra, chat: chat, store: store, actions: actions) }
        }
        model.header?.shown = { watch.current } // the palette's switches: the page's last state, no watch armed
        model.chatMenuItems = actions.menuItems
        model.sessionMenuItems = actions.sessionMenuItems
        model.onSearchWeb = actions.searchWeb
    }

    /// [+] New tab's column: a New Tab page in the chat's folder (or `cwd`, New Chat Here), moved to
    /// a new split on its right unless not `split`. The page's choices
    /// replace it in whichever pane it is in then. Returns whether the page was started.
    private func openNewTabColumn(beside provisional: String, machine: String? = nil, cwd: String? = nil, split: Bool = true) -> Bool {
        let chat = resolve(provisional, machine: machine ?? "")
        // The page opens on the chat's machine: that machine's folders, never this Mac's (cx-k21v).
        let scoped = tabKey(chat, machine: machine)
        guard let newTab = firstPageNewTab?(cwd ?? record(for: scoped)?.store.tab(id: scoped.key)?.cwd, scoped) else { return false }
        return openBeside(provisional, machine: scoped.machine, split: split) { pane, daemon, direction in try self.open(in: pane, of: daemon, newTab: newTab, split: direction) }
    }

    private func openSubagent(_ agent: String, of session: String, focus: Bool, asked: Bool? = nil, beside provisional: String, machine: String? = nil) -> Bool { // the tracker (AgentSubagentPanes) decides; the app opens and moves the tab
        let source = resolve(provisional, machine: machine ?? "") // one tracker per source chat (AgentSubagentPanes.chat)
        return AgentSubagentPanes.chat(session, source: source).open(agent, focus: focus, asked: asked, chat: provisional, hooks: .init(isOpen: { [weak self] key in self?.subagentTabIsBeside(source, key, machine: machine) ?? false }, focus: { [weak self] key, script in _ = self?.actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: self?.resolve(key, machine: machine ?? "") ?? key), arguments: script ? ["focus": .bool(true)] : [:], origin: script ? .script : .user).onMachine(machine)) },
            // An unfocused tab in the right column is selected there (shown, focus stays); in the chat's own pane it waits in the strip.
            // openOnRight decides again in its turn (RightColumnTurns): the decision that placed it is the one passed to created.
            place: { [weak self] chat, _, created, finished in self?.openOnRight(of: chat, machine: machine, origin: focus ? .user : .script, open: { [weak self] pane, daemon, split in guard let self else { throw CancellationError() }; let tab = try open(in: pane, of: daemon, session: session, split: split); revealTurn(AgentSubagentPanes.reveal(agent), in: tab.key, machine: daemon.machineID); return tab }, // the reveal is on the tab before its first show (view(for:) adopts the spare from it), not once the store answered
                created: { [weak self] key, decision in let scoped = AgentTabKey(machine: machine ?? "", key: key); created(key); SubagentTabTitles.shared.bind(agent, of: session, toTab: key) { [weak self] in self?.locateScoped(AgentTabKey(machine: scoped.machine, key: $0)) != nil }; if case .tab(.some) = decision, !focus { self?.selectInPaneScoped(scoped) } }, finished: finished) ?? false },
            column: { [weak self] in self?.rightColumnScoped(self?.tabKey($0, machine: machine) ?? AgentTabKey(machine: "", key: $0)) ?? .init() }, again: { [weak self] request in _ = self?.openSubagent(request.agent, of: session, focus: request.focus, asked: request.asked, beside: request.chat, machine: machine) })) }

    private func subagentTabIsBeside(_ source: String, _ candidate: String, machine: String? = nil) -> Bool { // AgentSubagentPanes.isBeside
        let at = { (found: (pane: PaneID, daemon: DaemonService)?) in found.map { (pane: $0.pane, owner: ObjectIdentifier($0.daemon)) } }
        let sourceKey = resolvedKey(AgentTabKey(machine: machine ?? "", key: source))
        return AgentSubagentPanes.isBeside(source: at(locateScoped(sourceKey)), candidate: at(locateScoped(AgentTabKey(machine: sourceKey.machine, key: resolve(candidate, machine: sourceKey.machine))))) { rightColumnScoped(sourceKey).panes.map { at(locatePaneScoped(sourceKey, $0)) } }
    }
    /// What chat tab `provisional` opens on its right, in its turn beside the chat (``RightColumnTurns``,
    /// with every other open there): it decides its place from the column as it is then (``RightColumnPlacement``), and
    /// `created` hears the new tab with that decision. `finished` (or a refusal) ends the turn. An open asked for while
    /// another is still moving into place waits and answers true.
    @discardableResult
    func openOnRight(of provisional: String, machine: String? = nil, origin: ActionOrigin = .user, splitRight: Bool = false, open: @escaping AgentTabOpen, // splitRight: always a split right of the chat (`/side`)
                     created: (@MainActor (_ key: String, _ decision: RightColumnPlacement.Decision<String>) -> Void)? = nil,
                     finished: (@MainActor (_ moved: Bool) -> Void)? = nil) -> Bool {
        var opened = true
        var ran = true // the turn ran in this call (false once it waits for another open)
        let scoped = resolvedKey(tabKey(provisional, machine: machine))
        let now = seriallyScoped(scoped) { [weak self] done in
            guard let self else { finished?(false); return done() }
            let decision: RightColumnPlacement.Decision<String> = splitRight ? .splitRight : RightColumnPlacement.decide(rightColumnScoped(scoped))
            // A created hook is always passed, so openBeside and main pane layout call `finished` on every path once they opened.
            opened = place(decision, of: provisional, machine: scoped.machine, origin: origin, inMainPane: !splitRight, open: open, created: { key in created?(key, decision) },
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
    private func place(_ decision: RightColumnPlacement.Decision<String>, of provisional: String, machine: String? = nil, origin: ActionOrigin, inMainPane: Bool, open: AgentTabOpen, created: @escaping @MainActor (String) -> Void, finished: @escaping @MainActor (_ moved: Bool) -> Void) -> Bool {
        // Nothing on the right (a split right, or a chat too narrow to split: #27789's review at 84718cf2): main pane layout decides first.
        let rightIsEmpty = switch decision { case .splitRight, .tab(nil): true; case .splitBelow, .tab(.some): false }
        let scoped = resolvedKey(tabKey(provisional, machine: machine))
        if rightIsEmpty, inMainPane, let placed = openInMainPaneScoped(scoped, origin == .user, { try open($0, $1, nil) }, created, finished) { return placed }
        switch decision {
        case .splitRight: return openBeside(provisional, machine: scoped.machine, origin: origin, open: open, created: created, finished: finished)
        case .splitBelow(let pane): return openBeside(provisional, machine: scoped.machine, in: pane, direction: "down", origin: origin, open: open, created: created, finished: finished)
        case .tab(let pane): return openBeside(provisional, machine: scoped.machine, in: pane, split: false, origin: origin, open: open, created: created, finished: finished)
        }
    }

    /// A tab in chat tab `provisional`'s pane (or right-column pane `paneKey`), on its `direction` side when `split` (right or below: made in its split,
    /// ``openInSplit``; else made there, then moved); else a tab there, selected now as a link's stand-in is, never once the store answered (Leo 2026-11-05: "things just
    /// don't open up fast enough on the right"), focused for a click, and never over the chat unasked. A split for a main pane chat `main` (``openInMainPane``) is a tab on its right.
    @discardableResult
    func openBeside(_ provisional: String, machine: String? = nil, in paneKey: String? = nil, split: Bool = true, direction: String = "right", origin: ActionOrigin = .user, main: String? = nil, open: AgentTabOpen, created: (@MainActor (String) -> Void)? = nil, finished: (@MainActor (_ moved: Bool) -> Void)? = nil) -> Bool {
        let scoped = tabKey(provisional, machine: machine)
        if split, let main, let placed = openInMainPaneScoped(resolvedKey(AgentTabKey(machine: scoped.machine, key: main)), origin == .user, { try open($0, $1, nil) }, created, finished) { return placed }
        let located = if let paneKey { locatePaneScoped(resolvedKey(scoped), paneKey) } else { locateScoped(resolvedKey(scoped)) }
        guard let (pane, daemon) = located else { return false }
        let inSplit = split ? SplitDirection(splitFirst: direction, served: daemon.supports(DaemonCapability.conversationTabSplit.rawValue)) : nil
        guard let pending = try? open(pane, daemon, inSplit) else { return false }
        if inSplit != nil { return openInSplit(pending, beside: resolvedKey(scoped), origin: origin, created: created, finished: finished) }
        guard split || created != nil else { return true }
        if !split, paneKey != nil || origin == .user { selectInPaneScoped(AgentTabKey(machine: daemon.machineID, key: pending.key)); if origin == .user { _ = showSplitScoped(resolvedKey(scoped), pending.key, true) } }
        // task-owner: one tab creation, then one move (or, not `split`, one focus) of that tab
        Task { [weak self] in
            guard let tab = try? await pending.value(), let self, await TabMirror.reaches(tab.key, in: { self.locateScoped(AgentTabKey(machine: scoped.machine, key: $0)) }) else { finished?(false); return }; created?(tab.key)
            guard split else { if origin == .user { _ = actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.key), origin: origin).onMachine(scoped.machine)) }; finished?(false); return } // an unfocused (script) open leaves focus where it is
            _ = actionRegistry?.perform("tab.moveToNewSplit", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.key), arguments: ["direction": .string(direction), "keepFocus": .bool(origin == .script)], origin: origin).onMachine(scoped.machine)) // script: an unfocused subagent open
            if let finished { finished(await TabMirror.reaches(tab.key, in: { [weak self] in self?.locateScoped(AgentTabKey(machine: scoped.machine, key: $0)).flatMap { $0.pane != pane ? $0 : nil } })) } // stacking waits for the move
        }
        return true
    }

    /// `pending`'s tab in its new split, shown in this turn (``showSplit``) as a link's is; the turn ends once the store lists it, with no move.
    private func openInSplit(_ pending: AgentTabPending, beside chat: AgentTabKey, origin: ActionOrigin, created: (@MainActor (String) -> Void)?,
                             finished: (@MainActor (_ moved: Bool) -> Void)?) -> Bool {
        let landed = showSplitScoped(chat, pending.key, origin == .user) // an unfocused (script) open leaves focus where it is
        Task { [weak self] in // task-owner: one tab creation in its split
            guard let tab = try? await pending.value(), let self, await TabMirror.reaches(tab.key, in: { self.locateScoped(AgentTabKey(machine: chat.machine, key: $0)) }) else { finished?(false); return }
            landed(tab.surface)
            created?(tab.key)
            finished?(true)
        }
        return true
    }
}
