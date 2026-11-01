import AppKit
public import CmuxNextActions
public import CmuxNextAgentActivity
public import CmuxNextAgentPane
import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextSidebar
import Foundation

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

    /// Follows the setting, acpmux's windows, the lanes, every machine's live tabs and the
    /// user's pins from now on; a row opens its chat with `open` (the app's Open Chat path).
    public func start(workspaces: @escaping @MainActor @Sendable () -> [WorkspaceModel],
                      liveTabs: (@escaping @MainActor @Sendable () -> [TabModel])? = nil, localHost: String?,
                      open: @escaping @MainActor (String) -> Void, windows: AcpmuxChatWindows,
                      lanes: AgentLaneStore = .shared, history: SidebarChatHistory = .shared) {
        guard task == nil else { return }
        history.onOpen = open
        let earlier = windows.window(Self.earlierWindow)
        let pinned = windows.window(Self.pinnedWindow)
        let liveTabs = liveTabs
        // task-owner: the app (one feed for the app's life); event-driven (Observation). One value
        // per change of what the history shows besides the index (the windows' specs for acpmux)
        // or of a window's rows (the state, O(visible rows)).
        task = Task {
            for await shown in ObservationStream({ () -> Shown? in
                guard DesignSettings.shared.sidebarSections.sessionTree else { return nil }
                let inputs = Inputs(live: liveTabs.map { Self.liveChats($0(), lanes: lanes, localHost: localHost) }
                                       ?? Self.liveChats(workspaces(), lanes: lanes.lanes, localHost: localHost),
                                    pinned: history.pinned, limit: history.limit, folded: history.earlierFolded)
                return Shown(inputs: inputs, state: Self.state(earlier: earlier.rows, pinned: pinned.rows, inputs: inputs))
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

        /// Earlier's window: one more row than the page, so the history knows Show More; one row
        /// while folded, so its header knows whether Earlier has a chat.
        var earlierSpec: AcpmuxChatWindows.Spec {
            AcpmuxChatWindows.Spec(window: SidebarChatHistoryFeed.earlierWindow, limit: folded ? 1 : max(0, limit) + 1,
                                   topLevel: true, exclude: live.union(pinned).sorted())
        }

        var pinnedSpec: AcpmuxChatWindows.Spec {
            AcpmuxChatWindows.Spec(window: SidebarChatHistoryFeed.pinnedWindow, limit: max(1, pinned.count), topLevel: false,
                                   keys: pinned)
        }
    }

    /// The history of the two windows' rows. The local skip (`live`, `pinned`) holds only until
    /// acpmux answers a new spec, so a chat just pinned never lists twice.
    static func state(earlier: [AcpmuxChat], pinned: [AcpmuxChat], inputs: Inputs) -> SidebarChatHistoryState {
        let pinnedByID = Dictionary(pinned.map { ($0.id, historyChat($0)) }, uniquingKeysWith: { first, _ in first })
        return SidebarChatHistoryState.make(newest: earlier.lazy.map(historyChat), chat: { pinnedByID[$0] }, live: inputs.live,
                                            pinned: inputs.pinned, limit: inputs.limit, folded: inputs.folded)
    }

    /// The chats an open workspace shows: those its agent tabs' acpmux sessions on this Mac continue.
    static func liveChats(_ workspaces: [WorkspaceModel], lanes: [String: AgentActivityLane], localHost: String?) -> Set<String> {
        var live: Set<String> = []
        for workspace in workspaces {
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
                guard let ref = tab.agentSession, ref.host == localHost, let session = ref.session,
                      let chat = lanes[session]?.chat else { continue }
                live.insert(chat)
            }
        }
        return live
    }

    /// The live-tab projection used by the app. It observes each session's chat binding only;
    /// turn-state changes, usage detail and terminal output leave the projection unchanged.
    static func liveChats(_ tabs: [TabModel], lanes: AgentLaneStore, localHost: String?) -> Set<String> {
        var live: Set<String> = []
        for tab in tabs {
            guard let ref = tab.agentSession, ref.host == localHost, let session = ref.session,
                  let chat = lanes.chat(session) else { continue }
            live.insert(chat)
        }
        return live
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
