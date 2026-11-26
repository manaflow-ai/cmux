import AppKit
public import CmuxNextActions
public import CmuxNextAgentActivity
public import CmuxNextAgentPane
import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextSidebar
import Foundation
import Observation

/// Feeds the session tree's chat history (`sidebar.sessionTree`, hq#2569 #6) from acpmux's chat
/// index: the pinned chats, and Earlier, the newest chats that no open workspace of this Mac shows,
/// one page at a time. A workspace shows a chat when one of its agent tabs runs an acpmux session
/// that continues it (the lane's `chat`). Off, it leaves `SidebarChatHistory.state` nil.
///
/// acpmux owns the list (P-RUST, layer-ownership.md rules 1-3): Earlier and Pinned are two windows
/// over its index (``AcpmuxChatWindows``), sorted, filtered and paged in Rust. The main thread holds
/// only their visible rows and applies one row diff per change; it never holds, copies or compares
/// the whole index (v2.2.9: 730 ms in the old whole-index setter's `==`).
@MainActor
public final class SidebarChatHistoryFeed {
    public static let shared = SidebarChatHistoryFeed()

    /// Earlier's window: the newest top-level chats that no open workspace shows and no pin holds.
    public nonisolated static let earlierWindow = "sidebar.history.earlier"
    /// Pinned's window: the pinned chats, in pin order.
    public nonisolated static let pinnedWindow = "sidebar.history.pinned"

    private var task: Task<Void, Never>?
    /// Follows the live tab list (which tabs, never their fields) while the history shows.
    private var listTask: Task<Void, Never>?
    /// One observation per live tab of the chat it shows (main-thread-scheduling.md section 3, O6): a tab's change
    /// re-reads that tab only, never every live tab, and arrives as one change (`ObservedItems.Change`): the joined
    /// set is updated for that tab's chat before and now, with no pass over the live tabs (the person's session has
    /// 1600 of them).
    private var observed: ObservedItems<TabModel, LiveChat>?
    /// The live tabs listed now.
    private var listed: [TabModel] = []
    /// By chat: how many live tabs show it. Right while each tab is listed once (the store's are): a tab listed two
    /// times has one observation and two counts until the next change of the list.
    private var holders: [String: Int] = [:]
    /// The chats the live tabs show, joined: what the history reads.
    private let joined = JoinedLiveChats()

    /// One live tab's chat (nil: it shows none of this Mac's acpmux chats).
    nonisolated struct LiveChat: Equatable, Sendable {
        var chat: String?
    }

    /// The chats every live tab shows; nil while the history is off.
    @Observable @MainActor final class JoinedLiveChats {
        var live: Set<String>?
    }

    /// Follows the setting, acpmux's windows, the lanes, every machine's live tabs and the
    /// user's pins from now on; a row opens its chat with `open` (the app's Open Chat path).
    /// The live tab list is observed without reading any tab's fields, and each tab's chat is its own
    /// observation, so one tab's change re-reads that tab only and the history reads the joined set.
    public func start(liveTabs: @escaping @MainActor @Sendable () -> [TabModel], localHost: String?,
                      open: @escaping @MainActor (String) -> Void, windows: AcpmuxChatWindows,
                      lanes: AgentLaneStore = .shared, history: SidebarChatHistory = .shared) {
        guard task == nil else { return }
        history.onOpen = open
        let earlier = windows.window(Self.earlierWindow)
        let pinned = windows.window(Self.pinnedWindow)
        let joined = joined
        observed = ObservedItems(item: { tab in LiveChat(chat: Self.liveChat(tab, lanes: lanes, localHost: localHost)) },
                                 same: { $0 == $1 }, changedItem: { [weak self] change in self?.itemChanged(change) })
        // task-owner: the app (one feed for the app's life); event-driven (Observation)
        listTask = Task { [weak self] in
            for await trigger in ObservationStream({ () -> ObservationTrigger<[TabModel]?> in
                ObservationTrigger(DesignSettings.shared.sidebarSections.sessionTree ? liveTabs() : nil)
            }) {
                guard let self else { return }
                guard let tabs = trigger.value else {
                    observed?.cancelAll()
                    listed = []
                    holders = [:]
                    if joined.live != nil { joined.live = nil }
                    continue
                }
                listed = tabs
                listChanged()
            }
        }
        // task-owner: the app (one feed for the app's life); event-driven (Observation). One value
        // per change of what the history shows besides the index (the windows' specs for acpmux)
        // or of a window's rows (the state, O(visible rows)).
        task = Task {
            for await shown in ObservationStream({ () -> Shown? in
                guard DesignSettings.shared.sidebarSections.sessionTree, let live = joined.live else { return nil }
                let inputs = Inputs(live: live, pinned: history.pinned, limit: history.limit, folded: history.earlierFolded)
                return Shown(inputs: inputs, state: Self.state(earlier: earlier.rows, more: earlier.hasMore, pinned: pinned.rows,
                                                               inputs: inputs, loading: !earlier.hasAnswered))
            }) {
                if let shown {
                    windows.open(shown.inputs.earlierSpec)
                    windows.open(shown.inputs.pinnedSpec)
                } else {
                    windows.close(Self.earlierWindow)
                    windows.close(Self.pinnedWindow)
                }
                if history.state != shown?.state { history.state = shown?.state }
            }
        }
    }

    /// The live tab list changed: the live tabs' chats now. Only tabs new to the list are read (their own
    /// observations keep the rest), but every live tab is visited, so this runs for a list change only. The
    /// joined set is written only when it changed.
    private func listChanged() {
        guard let observed else { return }
        holders = [:]
        for chat in observed.items(for: listed, id: { "\(ObjectIdentifier($0))" }).compactMap(\.chat) {
            holders[chat, default: 0] += 1
        }
        let live = Set(holders.keys)
        if joined.live != live { joined.live = live }
    }

    /// One live tab's chat changed: the chat it showed leaves the joined set when no other tab shows it, and the
    /// chat it shows now joins when no tab showed it. No other tab is visited. What still follows the count of open
    /// chats after such a change: Earlier's spec, which names them all for acpmux (``Inputs/earlierSpec``).
    private func itemChanged(_ change: ObservedItems<TabModel, LiveChat>.Change) {
        let chats = [change.old.chat, change.new.chat].compactMap { $0 }
        ObservationWork.visited(chats.count, "SidebarChatHistoryFeed.join")
        if let chat = change.old.chat, let count = holders[chat] {
            holders[chat] = count > 1 ? count - 1 : nil
            if count == 1 { joined.live?.remove(chat) }
        }
        if let chat = change.new.chat {
            let count = holders[chat] ?? 0
            holders[chat] = count + 1
            if count == 0 { joined.live?.insert(chat) }
        }
    }

    /// The history's inputs and its state from them and the windows' rows.
    nonisolated struct Shown: Equatable, Sendable {
        var inputs: Inputs
        var state: SidebarChatHistoryState
    }

    /// What the history shows, besides the index: the chats open workspaces show, the pins, the page.
    nonisolated struct Inputs: Equatable, Sendable {
        var live: Set<String>
        var pinned: [String]
        var limit: Int
        var folded: Bool

        /// Earlier's window: the page (acpmux says whether more chats wait past it, `hasMore`); one
        /// row while folded, so its header knows whether Earlier has a chat.
        var earlierSpec: AcpmuxChatWindows.Spec {
            AcpmuxChatWindows.Spec(window: SidebarChatHistoryFeed.earlierWindow, limit: folded ? 1 : max(1, limit),
                                   topLevel: true, exclude: live.union(pinned).sorted())
        }

        var pinnedSpec: AcpmuxChatWindows.Spec {
            AcpmuxChatWindows.Spec(window: SidebarChatHistoryFeed.pinnedWindow, limit: max(1, pinned.count), topLevel: false,
                                   keys: pinned)
        }
    }

    /// The history of the two windows' rows; `more`: acpmux's Earlier window has chats past its page.
    /// `loading`: acpmux never sent Earlier's rows yet (connecting, or its index still starting), so an
    /// empty page is not an empty history. The local skip (`live`, `pinned`) holds only until acpmux
    /// answers a new spec, so a chat just pinned never lists twice.
    static func state(earlier: [AcpmuxChat], more: Bool, pinned: [AcpmuxChat], inputs: Inputs,
                      loading: Bool = false) -> SidebarChatHistoryState {
        let pinnedByID = Dictionary(pinned.map { ($0.id, historyChat($0)) }, uniquingKeysWith: { first, _ in first })
        return SidebarChatHistoryState.make(newest: earlier.lazy.map(historyChat), chat: { pinnedByID[$0] }, live: inputs.live,
                                            pinned: inputs.pinned, limit: inputs.limit, folded: inputs.folded, more: more,
                                            loading: loading)
    }

    /// The live-tab projection: the chats `tabs` show. It reads each session's chat binding only;
    /// turn-state changes, usage detail and terminal output leave the projection unchanged.
    static func liveChats(_ tabs: [TabModel], lanes: AgentLaneStore, localHost: String?) -> Set<String> {
        Set(tabs.compactMap { liveChat($0, lanes: lanes, localHost: localHost) })
    }

    /// The chat one tab shows: its agent session's on this Mac (`localHost`), by the lane's chat binding.
    static func liveChat(_ tab: TabModel, lanes: AgentLaneStore, localHost: String?) -> String? {
        guard let ref = tab.agentSession, ref.host == localHost, let session = ref.session else { return nil }
        return lanes.chat(session)
    }

    /// Pin or Unpin Chat: its target is a history row's chat (`sidebar-item:<chat key>`).
    public static let togglePinAction: ActionID = "sidebar.chat.togglePin"

    /// Binds Pin or Unpin Chat to `history`'s pins and gives each history row its right-click menu
    /// from `registry` (that one action on the row's chat), so the menu, `cmux action run` and
    /// the palette's keys all run the same handler (scripts/cmux-next/check-menu-actions.py).
    public static func bind(into registry: ActionRegistry, history: SidebarChatHistory = .shared) {
        registry.bind(togglePinAction, invoke: { [weak history] invocation in
            guard let history, let target = invocation.target, target.kind == .sidebarItem else { return }
            history.setPinned(target.id, !history.isPinned(target.id))
        })
        history.makeMenu = { [weak registry] key in
            registry?.makeContextMenu(for: .sidebarItem, target: ActionTargetRef(kind: .sidebarItem, id: key),
                                      entries: [.action(togglePinAction)])
        }
    }

    /// A chat as the history lists it: its title, else its folder's name, else its harness.
    static func historyChat(_ chat: AcpmuxChat) -> SidebarHistoryChat {
        let folder = chat.cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        return SidebarHistoryChat(id: chat.id, title: chat.title ?? folder ?? chat.harness, updatedAt: chat.updatedAt,
                                  harness: chat.harness)
    }
}
