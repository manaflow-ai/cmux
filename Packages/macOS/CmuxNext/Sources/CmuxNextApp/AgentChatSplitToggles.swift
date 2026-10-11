import CmuxNextAgentPane
import CmuxNextDaemon

/// The chat header's Terminal and Browser splits and its Changes diff (acpmux header/quickActions.ts), each
/// the panel its button owns, as in Claude Code desktop's top right (cx-00n1). Toggling (`mode:
/// "toggle"`, the default, as in T3 Chat and ChatGPT): the first click opens its split beside the
/// chat, the second closes that split, and a click after the user closed it opens a new one. Either
/// mode lines the splits up right of the chat in the order they opened (cx-qom0): a new one opens
/// right of the last one still beside the chat, not between the chat and the earlier ones.
///
/// One per chat tab. Opening records the tabs of the chat's workspace; the split's tab is the tab of
/// the button's kind that appeared after that, read from the store mirror when it is needed, so no
/// reply plumbing from the split handlers is needed and a split the user closed or moved away from
/// the workspace simply opens again. Durable tab ids, never pane handles (refreshed on every
/// snapshot).
@MainActor
final class AgentChatSplitToggles {
    /// The header actions that own a panel, sorted.
    static let panels = [changes, "splitBrowserRight", "splitRight"]
    /// Changes: the diff viewer's page.
    static let changes = "openDiffViewer"

    /// Whether `tab` is the panel header action `id` opens: a terminal, a browser, or a diff page.
    private static func owns(_ id: String, _ tab: TabModel) -> Bool {
        switch id {
        case "splitRight": tab.kind == .pty
        case "splitBrowserRight": tab.kind == .browser
        case changes: tab.page == "diff"
        default: false
        }
    }

    /// The splits this chat's header opened, oldest first: the action and the workspace's tab ids
    /// just before it ran.
    private var opened: [(id: String, baseline: Set<String>)] = []
    private static let remembered = 8

    /// Toggles header action `id` on chat tab `chat` (in `store`): closes the split it opened when
    /// that tab is still in the chat's workspace, else opens one (an action that opens no tracked
    /// kind just runs).
    func toggle(_ id: String, cwd: String?, chat: String, store: DaemonStore?, actions: AgentChatTabActions) {
        guard Self.panels.contains(id), let store, let tabs = Self.workspaceTabs(of: chat, in: store) else {
            return actions.run(id, cwd: cwd)
        }
        if let index = opened.lastIndex(where: { $0.id == id }),
           let split = Self.split(opened.remove(at: index), in: tabs, chat: chat) {
            return actions.close(tab: split.id)
        }
        open(id, cwd: cwd, chat: chat, tabs: tabs, store: store, actions: actions)
    }

    /// Opens header action `id`'s split (`mode: "open"`): another one on every click.
    func open(_ id: String, cwd: String?, chat: String, store: DaemonStore?, actions: AgentChatTabActions) {
        guard Self.panels.contains(id), let store, let tabs = Self.workspaceTabs(of: chat, in: store) else {
            return actions.run(id, cwd: cwd)
        }
        open(id, cwd: cwd, chat: chat, tabs: tabs, store: store, actions: actions)
    }

    private func open(_ id: String, cwd: String?, chat: String, tabs: [TabModel], store: DaemonStore,
                      actions: AgentChatTabActions) {
        let anchor = opened.reversed().lazy
            .compactMap { Self.split($0, in: tabs, chat: chat) }
            .first { Self.beside(chat, $0, in: store) }
        // Open mode adds one per click: keep the recent ones, enough to find the last split beside the chat.
        opened = Array(opened.suffix(Self.remembered - 1))
        opened.append((id: id, baseline: Set(tabs.map(\.id))))
        if id == Self.changes {
            // The chat's repository, placed as an agent's diff is (AgentBesidePlacement): in the
            // column of the last panel beside the chat, else a new column right of the chat.
            return actions.runBeside(id, path: cwd ?? store.tab(id: chat)?.cwd, on: anchor?.id)
        }
        // Split Right takes its folder from the tab it splits: from beside another split, the chat's.
        actions.run(id, cwd: anchor == nil ? cwd : cwd ?? store.tab(id: chat)?.cwd, on: anchor?.id)
    }

    /// The tab split `entry` opened, while it is in the chat's workspace.
    private static func split(_ entry: (id: String, baseline: Set<String>), in tabs: [TabModel], chat: String) -> TabModel? {
        tabs.first { owns(entry.id, $0) && $0.id != chat && !entry.baseline.contains($0.id) }
    }

    /// Whether `tab` sits in its own pane in the chat's part of the layout: its screen, and its
    /// column on a scrolling screen. A split the chat dock sent to the strip, or one the user moved
    /// into the chat's pane or elsewhere, is no anchor.
    private static func beside(_ chat: String, _ tab: TabModel, in store: DaemonStore) -> Bool {
        guard let chatPane = store.tab(id: chat).flatMap({ store.pane(containing: $0.surface) }),
              let pane = store.pane(containing: tab.surface), pane !== chatPane else { return false }
        let region = { (handle: PaneID) -> String? in
            for screen in store.workspace(containing: handle)?.screens ?? [] where screen.panes.contains(where: { $0.handle == handle }) {
                let column = screen.columns.first { $0.layout.paneIDs.contains(handle) }
                return "\(screen.id)/\(column.map { "\($0.id.rawValue)" } ?? "")"
            }
            return nil
        }
        guard let mine = region(pane.handle) else { return false }
        return mine == region(chatPane.handle)
    }

    /// The chat header's state (cx-00n1): the tab's pin, whether the panes beside the chat show,
    /// and the splits whose button is lit, the ones a toggle click would close (each button's last
    /// split, while it is in the chat's workspace). One read, so ``AgentChatHeaderWatch`` observes
    /// exactly what the page shows.
    func headerState(chat: String, store: DaemonStore?) -> AgentPaneHeaderState {
        guard let store else { return AgentPaneHeaderState() }
        let tabs = Self.workspaceTabs(of: chat, in: store) ?? []
        let lit = Self.panels.filter { id in
            opened.last { $0.id == id }.flatMap { Self.split($0, in: tabs, chat: chat) } != nil
        }
        return AgentPaneHeaderState(pinned: store.tab(id: chat)?.pinned ?? false,
                                    sideTabs: Self.sideTabs(of: chat, in: store) == .shown, lit: lit)
    }

    /// [+] New tab, which becomes Hide tabs in the same spot (cx-qom0, ChatGPT's right column). On a
    /// chat alone, `openColumn` opens a New Tab page right of it. With panes beside the chat, the
    /// click hides them by zooming the chat, which closes nothing; on a zoomed chat it shows them
    /// again. Returns whether the panes beside the chat show after the click; nil when the store
    /// does not list the chat.
    /// `openColumn` returns whether it started the page; until the page's split shows (the page is
    /// made, then moved), a second click opens no second page.
    func sideTabs(chat: String, store: DaemonStore?, actions: AgentChatTabActions, openColumn: () -> Bool,
                  now: ContinuousClock.Instant = .now) -> Bool? {
        guard let store, let state = Self.sideTabs(of: chat, in: store) else { return nil }
        switch state {
        case .alone:
            if let opening, now - opening < Self.openingWait { return true }
            guard openColumn() else { return false }
            opening = now
            return true
        case .shown, .hidden:
            opening = nil
            actions.run("toggleSplitZoom", cwd: nil)
            return state == .hidden
        }
    }

    /// When [+] last started a New Tab page column.
    private var opening: ContinuousClock.Instant?
    /// How long a started column may take to show before a click opens another.
    private static let openingWait: Duration = .seconds(3)

    enum SideTabs { case alone, shown, hidden }

    /// Whether chat tab `chat` is alone on its screen, has panes showing beside it, or hides them
    /// (its pane zoomed).
    static func sideTabs(of chat: String, in store: DaemonStore) -> SideTabs? {
        guard let pane = store.tab(id: chat).flatMap({ store.pane(containing: $0.surface) }),
              let screen = store.workspace(containing: pane.handle)?.screens.first(where: { $0.panes.contains { $0 === pane } })
        else { return nil }
        if screen.zoomedPane == pane.handle { return .hidden }
        return screen.panes.count > 1 ? .shown : .alone
    }

    /// Every tab of the workspace that shows chat tab `chat`; nil when the store does not list it.
    private static func workspaceTabs(of chat: String, in store: DaemonStore) -> [TabModel]? {
        guard let surface = store.tab(id: chat)?.surface,
              let pane = store.pane(containing: surface),
              let workspace = store.workspace(containing: pane.handle) else { return nil }
        return workspace.screens.flatMap { $0.panes.flatMap(\.tabs) }
    }
}
