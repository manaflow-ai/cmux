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
        let placed = beside == nil ? AgentBesidePlacement.placed(invocation, in: chatController, then: nil) : nil
        guard let pending = try? tabs.open(in: target.pane.handle, of: target.daemon, session: session) else { return false }
        beside?.selectWhenReportedKeepingFocus(surface: pending.surface)
        // task-owner: one tab creation, then its placement beside the chat
        Task { @MainActor in
            guard let tab = try? await pending.value(), await TabMirror.reaches(tab.key, in: tabs.locate) else { return finished(false) }
            placed?(tab.surface)
            created(tab.key)
            finished(true)
        }
        return true
    }

    /// A tiled pane: a split right of `anchor` (the chat), or below it (`down`, the newest tiled pane).
    private func tile(beside anchor: String, down: Bool, created: @escaping @MainActor (String) -> Void,
                      finished: @escaping @MainActor (Bool) -> Void) -> Bool {
        let services = self.services, session = self.session, tabs = services.agentTabs
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

    /// Equalizes the splits of session `session`'s tiled stack, then again each time one of its
    /// panes leaves the layout, until none is left.
    static func balance(_ session: String, services: AppServices) {
        let tracker = AgentSubagentPanes.session(session)
        let panes = tracker.tiled(isOpen: { services.agentTabs.locate($0) != nil })
            .compactMap { services.locateTab(services.agentTabs.resolve($0))?.1 }
        guard let content = panes.first.flatMap(services.paneController(for:))?.workspace else {
            tracker.balancing = nil
            return
        }
        let stack = Set(panes.map { LayoutPaneID($0.id) })
        let model = content.layoutModel
        for tree in trees(model) {
            for split in tree.splits {
                guard let node = tree.node(for: split), (node.a.panes + node.b.panes).allSatisfy(stack.contains) else { continue }
                model.equalizeSplit(split)
            }
        }
        // task-owner: the stack's watch, replaced by the next balance and ended with the stack (its
        // panes left the layout, or its tabs closed with their workspace)
        tracker.balancing = Task { @MainActor in
            let left = ObservationStream {
                tracker.tiled(isOpen: { services.agentTabs.locate($0) != nil }).isEmpty ? 0
                    : SubagentBeside.trees(model).flatMap(\.panes).filter(stack.contains).count
            }
            for await count in left where count < stack.count {
                if count > 0 { SubagentBeside.balance(session, services: services) } else { tracker.balancing = nil }
                return
            }
        }
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
