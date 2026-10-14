import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextLayout

/// Where a chat's subagent opens (`chat.subagentPane`; the tracker, ``AgentSubagentPanes``, keeps
/// one tab per subagent and runs one open at a time).
///
/// A row's click opens it beside the chat the way the chat's links do (ChatBeside): a tab in the
/// pane right of the chat, or, with none there, a new column right of it (a lone chat docks left,
/// AgentBesidePlacement); a click on an open one selects its tab. Keyboard focus stays in the chat.
///
/// Tile subagents (`tile`) opens each in a pane of its own: the first in a split right of the chat,
/// each later one below the newest tiled pane, so one stack holds them. The stack's splits stay
/// equal as panes join it and as they close; the chat's width and every other split are left alone.
///
/// Each tab is named for the subagent's task (`title`) and opens on its view (`subagent:<id>`).
@MainActor
struct SubagentBeside {
    let services: AppServices
    let session: String
    let how: AgentSubagentPanes.Open

    /// Shows subagent `agent` of chat tab `chat` (a provisional key resolves); false when nothing opened.
    func open(_ agent: String, beside chat: String) -> Bool {
        let tabs = services.agentTabs
        let isOpen: (String) -> Bool = { tabs.locate($0) != nil }
        return AgentSubagentPanes.session(session).open(agent, how: how, chat: chat, hooks: .init(
            isOpen: isOpen,
            show: { show($0, focus: $1) },
            place: { anchor, down, created, finished in
                let ready: @MainActor (String) -> Void = { key in
                    created(key)
                    tabs.revealTurn(AgentSubagentPanes.reveal(agent), in: key)
                    name(key)
                }
                return how.tile ? tile(beside: anchor, down: down, created: ready, finished: finished)
                    : placeTab(beside: chat, created: ready, finished: finished)
            },
            again: { request in
                _ = SubagentBeside(services: services, session: session, how: request.how).open(request.agent, beside: request.chat)
            },
            close: { key in
                _ = services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tabs.resolve(key)), origin: .script))
            }))
    }

    /// An open subagent's tab again: a tiled pane takes focus when asked; a tab is selected in its pane.
    private func show(_ key: String, focus: Bool) {
        let key = services.agentTabs.resolve(key)
        if how.tile, focus {
            _ = services.registry.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: key), origin: .user))
        } else if let (_, pane) = services.locateTab(key) {
            services.paneController(for: pane)?.select(StripTabID(key))
        }
    }

    /// A tab in the pane right of chat `chat`, or a new column right of it (ChatBeside's rule).
    private func placeTab(beside chat: String, created: @escaping @MainActor (String) -> Void,
                          finished: @escaping @MainActor (Bool) -> Void) -> Bool {
        let tabs = services.agentTabs, chat = tabs.resolve(chat)
        guard let (_, chatPane) = services.locateTab(chat), let chatController = services.paneController(for: chatPane) else { return false }
        let beside = ChatBeside.besidePane(of: chatPane, in: services.daemon(for: chatPane).store).flatMap(services.paneController(for:))
        let target = beside ?? chatController
        // With no pane there: made unselected in the chat's pane, then moved out (or the chat docks).
        // Placed before the open: the new tab is a chat of the same session, so once in the pane a
        // lone chat would no longer read as lone and would not dock.
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: chat), origin: .user)
        invocation.besideCaller = true
        invocation.newColumnBeside = true
        // The next open waits for the move (or the dock), so it finds the pane right of the chat.
        let (moves, moved) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let placement = beside == nil ? AgentBesidePlacement.placement(invocation, pane: chatPane, controller: chatController,
                                                                         services: services, then: nil, done: { moved.yield($0) }) : nil
        guard let pending = try? tabs.open(in: target.pane.handle, of: target.daemon, session: session) else {
            placement?.cancel()
            return false
        }
        beside?.selectWhenReportedKeepingFocus(surface: pending.surface)
        // task-owner: one tab creation, then its placement beside the chat
        Task { @MainActor in
            guard let tab = try? await pending.value(), await TabMirror.reaches(tab.key, in: tabs.locate) else {
                placement?.cancel()
                return finished(false)
            }
            placement?.place(tab.surface)
            created(tab.key)
            guard placement != nil else { return finished(true) }
            var done = moves.makeAsyncIterator()
            finished(await done.next() ?? false)
        }
        return true
    }

    /// A tiled pane: a split right of `anchor` (the chat), or below it (`down`, the newest tiled pane).
    /// With a pane right of the chat already (a row's click put one there and docked the chat), the
    /// first one goes below that pane instead, so the stack stays right of the chat.
    private func tile(beside anchor: String, down: Bool, created: @escaping @MainActor (String) -> Void,
                      finished: @escaping @MainActor (Bool) -> Void) -> Bool {
        let services = self.services, session = self.session, tabs = services.agentTabs
        var anchor = anchor, down = down
        if !down, let (_, chatPane) = services.locateTab(tabs.resolve(anchor)),
           let beside = ChatBeside.besidePane(of: chatPane, in: services.daemon(for: chatPane).store)?.tabs.first {
            anchor = beside.id
            down = true
        }
        return tabs.openBeside(anchor, direction: down ? "down" : "right", origin: how.focus ? .user : .script,
                               open: { pane, daemon in try tabs.open(in: pane, of: daemon, session: session) },
                               created: created, finished: { moved in
            finished(moved)
            if moved { SubagentBeside.balance(session, services: services) }
        })
    }

    /// Names tab `key` for the subagent's task.
    private func name(_ key: String) {
        guard let title = how.title else { return }
        _ = services.registry.perform("renameTab", invocation: ActionInvocation(
            target: ActionTargetRef(kind: .tab, id: key), arguments: ["name": .string(title)], origin: .script))
    }

    /// Equalizes the splits of session `session`'s tiled stack, then again each time the stack's
    /// panes in the layout change (one leaves, or one the layout listed late joins), until none is left.
    static func balance(_ session: String, services: AppServices) {
        let tracker = AgentSubagentPanes.session(session)
        guard let (model, stack) = self.stack(session, services: services), !stack.isEmpty else {
            tracker.balancing = nil
            return
        }
        for tree in trees(model) {
            for split in tree.splits {
                guard let node = tree.node(for: split), (node.a.panes + node.b.panes).allSatisfy(stack.contains) else { continue }
                model.equalizeSplit(split)
            }
        }
        // task-owner: the stack's watch, replaced by the next balance and ended with the stack (its
        // panes left the layout, or its tabs closed with their workspace)
        tracker.balancing = Task { @MainActor in
            for await now in ObservationStream({ SubagentBeside.stack(session, services: services)?.panes ?? [] }) where now != stack {
                if now.isEmpty { tracker.balancing = nil } else { SubagentBeside.balance(session, services: services) }
                return
            }
        }
    }

    /// The tiled stack's panes in the layout of its first pane's workspace: a pane of a tiled tab,
    /// unless it also holds a chat that isn't tiled (the chat's own pane). A tiled tab moved to
    /// another workspace, or a pane the layout doesn't list yet, is left out.
    private static func stack(_ session: String, services: AppServices) -> (LayoutModel, Set<LayoutPaneID>)? {
        let tabs = services.agentTabs
        let keys = AgentSubagentPanes.session(session).tiled(isOpen: { tabs.locate($0) != nil }).map { tabs.resolve($0) }
        let panes = keys.compactMap { services.locateTab($0)?.1 }
        guard let model = panes.first.flatMap(services.paneController(for:))?.workspace?.layoutModel else { return nil }
        let shown = Set(trees(model).flatMap(\.panes))
        let stack = panes.filter { pane in pane.tabs.allSatisfy { keys.contains($0.id) || !ChatColumnPlacement.isChat($0, services: services) } }
        return (model, Set(stack.map { LayoutPaneID($0.id) }).intersection(shown))
    }

    private static func trees(_ model: LayoutModel) -> [SplitNode] {
        model.screens.flatMap { screen -> [SplitNode] in
            switch screen.layout {
            case .splits(let root): [root]
            case .columns(let columns): columns.flatMap(\.trees)
            }
        }
    }
}
