import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextFloating

/// The chat header's Terminal and Browser splits, its Changes diff and its Preview page (acpmux
/// header/quickActions.ts), each the panel its button owns, as in Claude Code desktop's top right (cx-00n1). Toggling (`mode:
/// "toggle"`, the default, as in T3 Chat and ChatGPT): the first click opens its split beside the
/// chat, the second closes that split, and a click after the user closed it opens a new one. Either
/// mode lines the splits up right of the chat in the order they opened (cx-qom0): a new one opens
/// right of the last one still beside the chat, not between the chat and the earlier ones.
///
/// One per chat tab. Opening records the tabs of the chat's workspace; the split's tab is the tab of
/// the button's kind that appeared after that and that no later opening claims (Browser and Preview
/// both open browser tabs), read from the store mirror when it is needed, so no
/// reply plumbing from the split handlers is needed and a split the user closed or moved away from
/// the workspace simply opens again. Durable tab ids, never pane handles (refreshed on every
/// snapshot).
@MainActor
final class AgentChatSplitToggles {
    /// The header actions that own a panel, sorted.
    static let panels = [changes, files, preview, "splitBrowserRight", splitDown, "splitRight"]
    /// Split Down (cx-kk7lm): a terminal under the chat, the chat's own split, never beside another panel.
    static let splitDown = "splitDown"
    /// Changes: the diff viewer's page.
    static let changes = "openDiffViewer"
    /// Files: a tree of the chat's folder (cx-p4rt), off by default until styled.
    static let files = "files"
    /// Preview: a browser tab on the local page the chat's last turn started or mentioned.
    static let preview = AgentPaneModel.previewAction

    /// Whether `tab` is the panel header action `id` opens: a terminal, a browser, or a diff page.
    private static func owns(_ id: String, _ tab: TabModel) -> Bool {
        switch id {
        case "splitRight", splitDown, AgentChatTerminalAdds.added: tab.kind == .pty
        case "splitBrowserRight", preview: tab.kind == .browser
        case changes: tab.page == "diff"
        case files: tab.page == InternalPageID.files.rawValue
        default: false
        }
    }

    /// The splits this chat's header opened, oldest first: the action and the workspace's tab ids
    /// just before it ran.
    private var opened: [(id: String, baseline: Set<String>)] = []
    private static let remembered = 8

    /// Toggles header action `id` on chat tab `chat` (in `store`): closes the split it opened while it is in the chat's
    /// workspace, else opens one (an untracked kind just runs; Terminal always opens one with `terminalButtonAdds` on).
    /// `extra`: more arguments for the action (Changes' chat turn, ``DiffTurnArgument``).
    func toggle(_ id: String, cwd: String?, url: String? = nil, extra: [String: ActionValue] = [:], chat: String, store: DaemonStore?,
                actions: AgentChatTabActions) {
        if AgentChatTerminalAdds().adds(id) { return open(id, cwd: cwd, url: url, extra: extra, chat: chat, store: store, actions: actions) }
        guard Self.panels.contains(id), let store, let tabs = Self.workspaceTabs(of: chat, in: store) else {
            return Self.run(id, cwd: cwd, url: url, extra: extra, chat: chat, store: store, on: nil, actions: actions)
        }
        let splits = splits(in: tabs, chat: chat)
        if let index = opened.lastIndex(where: { $0.id == id }) {
            // A split the user closed is forgotten, so this button's older opening never claims a
            // tab the user makes later.
            opened.remove(at: index)
            if let split = splits[index] { return actions.close(tab: split.id) }
        }
        open(id, cwd: cwd, url: url, extra: extra, chat: chat, tabs: tabs, store: store, actions: actions)
    }

    /// Opens header action `id`'s split (`mode: "open"`): another one on every click.
    func open(_ id: String, cwd: String?, url: String? = nil, extra: [String: ActionValue] = [:], chat: String, store: DaemonStore?,
              actions: AgentChatTabActions) {
        guard Self.panels.contains(id), let store, let tabs = Self.workspaceTabs(of: chat, in: store) else {
            return Self.run(id, cwd: cwd, url: url, extra: extra, chat: chat, store: store, on: nil, actions: actions)
        }
        open(id, cwd: cwd, url: url, extra: extra, chat: chat, tabs: tabs, store: store, actions: actions)
    }

    private func open(_ id: String, cwd: String?, url: String?, extra: [String: ActionValue], chat: String, tabs: [TabModel],
                      store: DaemonStore, actions: AgentChatTabActions) {
        // Preview opens the chat's page; a click with none (its page closed elsewhere) opens nothing.
        if id == Self.preview, url == nil { return }
        let splits = splits(in: tabs, chat: chat)
        // Split Down splits the chat itself; the panels right of it line up after the last one of theirs.
        let anchor = id == Self.splitDown ? nil : opened.indices.reversed().lazy
            .filter { self.opened[$0].id != Self.splitDown }
            .compactMap { splits[$0] }
            .first { Self.beside(chat, $0, in: store) }
        // Open mode adds one per click: keep the recent ones, enough to find the last split beside the chat.
        opened = AgentChatTerminalAdds().room(in: opened, limit: Self.remembered) { $0.id }
        opened.append((id: AgentChatTerminalAdds().logged(id), baseline: Set(tabs.map(\.id))))
        Self.run(id, cwd: cwd, url: url, extra: extra, chat: chat, store: store, on: anchor?.id, actions: actions)
    }

    /// Runs header action `id` on tab `target` (the last panel beside the chat), or on the chat.
    /// Changes and Preview run as an agent's diff and browser do (AgentBesidePlacement): selected in
    /// the target's column, or with no target in a new column right of the chat.
    private static func run(_ id: String, cwd: String?, url: String?, extra: [String: ActionValue] = [:], chat: String,
                            store: DaemonStore?, on target: String?, actions: AgentChatTabActions) {
        switch id {
        case changes:
            // The chat's repository, whichever tab the diff opens beside; with the chat's turn for Last turn.
            let path = cwd ?? store?.tab(id: chat)?.cwd
            actions.runBeside(id, arguments: (path.map { ["path": .string($0)] } ?? [:]).merging(extra) { first, _ in first }, on: target)
        case files:
            actions.openFiles(cwd ?? store?.tab(id: chat)?.cwd, on: target)
        case preview:
            guard let url else { return }
            actions.runBeside("openBrowser", arguments: ["url": .string(url)], on: target)
        default:
            // Split Right takes its folder from the tab it splits: from beside another split, the chat's.
            actions.run(id, cwd: target == nil ? cwd : cwd ?? store?.tab(id: chat)?.cwd, on: target)
        }
    }

    /// The tab each opening (by index in `opened`) opened, while it is in the chat's workspace: the
    /// first tab of its kind made after it, newest opening first, so an older one never claims a
    /// later one's tab (Browser and Preview both open browser tabs, which the user can reorder).
    private func splits(in tabs: [TabModel], chat: String) -> [Int: TabModel] {
        var claimed = Set<String>(), found: [Int: TabModel] = [:]
        for index in opened.indices.reversed() {
            let entry = opened[index]
            guard let tab = tabs.first(where: {
                Self.owns(entry.id, $0) && $0.id != chat && !entry.baseline.contains($0.id) && !claimed.contains($0.id)
            }) else { continue }
            claimed.insert(tab.id)
            found[index] = tab
        }
        return found
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
    /// exactly what the page shows. `pullRequest` names the chat folder's pull request (cx-tcwj): nil
    /// for a chat whose folder is not on this Mac.
    func headerState(chat: String, store: DaemonStore?, pullRequest: AgentChatPullRequest? = nil) -> AgentPaneHeaderState {
        guard let store else { return AgentPaneHeaderState() }
        let tabs = Self.workspaceTabs(of: chat, in: store) ?? []
        let splits = splits(in: tabs, chat: chat)
        let lit = AgentChatTerminalAdds().lit(Self.panels.filter { id in
            opened.lastIndex { $0.id == id }.flatMap { splits[$0] } != nil
        })
        var state = AgentPaneHeaderState(pinned: store.tab(id: chat)?.pinned ?? false,
                                         sideTabs: Self.sideTabs(of: chat, in: store) == .shown, lit: lit,
                                         floatingChat: QuickComposerTunables.floatingChat.value)
        state.pullRequest = pullRequest?.badge(cwd: store.tab(id: chat)?.cwd)
        return state
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
