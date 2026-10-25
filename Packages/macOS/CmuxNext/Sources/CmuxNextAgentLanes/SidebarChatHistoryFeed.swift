import AppKit
public import CmuxNextActions
public import CmuxNextAgentActivity
public import CmuxNextAgentPane
import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextSidebar
import Foundation
public import Observation

/// Feeds the session tree's chat history (`sidebar.sessionTree`, hq#2569 #6) from acpmux's chat
/// index (the app's Chats feed mirror, metadata only): the pinned chats, and Earlier, the newest
/// chats that no open workspace of this Mac shows, one page at a time. A workspace shows a chat
/// when one of its agent tabs runs an acpmux session that continues it (the lane's `chat`).
/// Off, it leaves `SidebarChatHistory.state` nil.
@MainActor @Observable
public final class SidebarChatHistoryFeed {
    public static let shared = SidebarChatHistoryFeed()

    /// The chat index mirror. The app sets it on each index change (a copy-on-write value).
    public var chats = AcpmuxChatsStore()
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Follows the setting, the index, the lanes, every machine's `workspaces` and the user's pins
    /// from now on; a row opens its chat with `open` (the app's Open Chat path).
    public func start(workspaces: @escaping @MainActor @Sendable () -> [WorkspaceModel], localHost: String?,
                      open: @escaping @MainActor (String) -> Void, lanes: AgentLaneStore = .shared,
                      history: SidebarChatHistory = .shared) {
        guard task == nil else { return }
        history.onOpen = open
        // task-owner: the app (one feed for the app's life); event-driven (Observation)
        task = Task { [self] in
            for await state in ObservationStream({ [self] () -> SidebarChatHistoryState? in
                guard DesignSettings.shared.sidebarSections.sessionTree else { return nil }
                let live = Self.liveChats(workspaces(), lanes: lanes.lanes, localHost: localHost)
                return Self.state(chats, live: live, pinned: history.pinned, limit: history.limit, folded: history.earlierFolded)
            }) where history.state != state {
                history.state = state
            }
        }
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

    /// The history of `index`: reads the index lazily, newest first, only as far as the page needs.
    static func state(_ index: AcpmuxChatsStore, live: Set<String>, pinned: [String], limit: Int, folded: Bool) -> SidebarChatHistoryState {
        SidebarChatHistoryState.make(newest: index.newestFirst.lazy.map(historyChat), chat: { index.chat(id: $0).map(historyChat) },
                                     live: live, pinned: pinned, limit: limit, folded: folded)
    }

    /// A chat as the history lists it: its title, else its folder's name, else its harness.
    static func historyChat(_ chat: AcpmuxChat) -> SidebarHistoryChat {
        let folder = chat.cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        return SidebarHistoryChat(id: chat.id, title: chat.title ?? folder ?? chat.harness, updatedAt: chat.updatedAt)
    }
}
