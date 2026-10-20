import Foundation

/// The id and surface of a tab a create intent shows before the daemon has the tab: neither can
/// name a daemon tab.
public struct ProvisionalTab: Sendable, Hashable {
    /// The tab id prefix (`TabModel.id`) of a provisional tab.
    public static let idPrefix = "pending_tab_"
    /// Daemon surfaces count up from 1; provisional ones live far above them.
    private static let surfaceBase: UInt64 = 1 << 62
    @MainActor private static var next: UInt64 = 0

    /// The provisional tab's id (`TabModel.id`).
    public let id: String
    /// Its surface, far above every daemon surface.
    public let surface: SurfaceID

    /// A fresh provisional tab.
    @MainActor public init() {
        Self.next += 1
        id = Self.idPrefix + UUID().uuidString.lowercased()
        surface = SurfaceID(rawValue: Self.surfaceBase + Self.next)
    }

    /// The stand-in of a new conversation tab showing `conversation` (`new-conversation-tab`).
    public func conversation(_ conversation: ConversationTabRef) -> TabSnapshot {
        var snapshot = TabSnapshot(surface: surface, tabResourceID: ResourceID(rawValue: id), kind: .conversation,
                                   title: "about:blank", browserRenderer: "frontend")
        snapshot.conversation = conversation
        return snapshot
    }

    public static func isProvisional(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// Whether `surface` is a provisional tab's (never a daemon surface).
    public static func isProvisional(surface: SurfaceID) -> Bool { surface.rawValue > surfaceBase }

    /// A create intent's reply named the daemon's tab `surface`: from now on the provisional tab
    /// shows only while the records lack that surface, so the two never show side by side.
    @MainActor public static func created(_ transaction: ClientTransactionID, surface: SurfaceID, in store: DaemonStore) {
        guard store.intentLog.contains(transaction) else { return }
        store.intentLog.noteCreated(transaction, surface: surface)
        if store.tabsBySurface[surface] != nil, !store.overlayLifted, store.applyDepth == 0 {
            store.withOverlayLifted(writer: "intent created") {}
        }
        CancelledCreation.requestCloses(in: store)
    }

    /// The daemon's tab of a create intent arrived carrying the intent's transaction (the event
    /// can come before the reply): the provisional tab gives way to it in this apply, and the
    /// store reports both ids (`DaemonStore.onTabCreated`, `onPageTabCreated` for a page tab).
    @MainActor static func echoed(_ event: DaemonEvent, transaction: ClientTransactionID, in store: DaemonStore) {
        if case .paneAdded(let delta) = event { return echoedSplit(delta, transaction: transaction, in: store) }
        guard case .tabAdded(let delta) = event,
              let entry = store.intentLog.entries.first(where: { $0.transaction == transaction }),
              entry.createdSurface != delta.surface, // `matched` paired it already
              let provisional = createdTab(of: entry.kind), let tab = store.tabsBySurface[delta.surface] else { return }
        store.intentLog.noteCreated(transaction, surface: delta.surface)
        guard !entry.closeWhenCreated else { return } // closed first: nothing moves to it
        let id = provisional.tabResourceID?.rawValue ?? ""
        if provisional.conversation?.page != nil { store.onPageTabCreated?(id, tab) } else { store.onTabCreated?(id, tab) }
    }

    /// The provisional tab a create intent shows: a created tab's, or a new workspace's first tab.
    private static func createdTab(of intent: Intent) -> TabSnapshot? {
        switch intent {
        case .createTab(_, let provisional): provisional
        case .createWorkspace(let provisional, _): provisional.tab
        default: nil
        }
    }

    /// The daemon's pane of a conversation tab's split (`conversation-tab-split-v1`) arrived
    /// carrying the split intent's transaction: its one tab is the provisional tab's, reported
    /// in this apply as for a create (so view state moves before the pane shows).
    @MainActor private static func echoedSplit(_ delta: PaneDelta, transaction: ClientTransactionID, in store: DaemonStore) {
        guard let entry = store.intentLog.entries.first(where: { $0.transaction == transaction }),
              case .splitPane(_, _, _, let provisional) = entry.kind, let wanted = provisional.tab,
              let tab = store.pane(delta.pane)?.tabs.first, entry.createdSurface != tab.surface else { return }
        store.intentLog.noteCreated(transaction, surface: tab.surface)
        guard !entry.closeWhenCreated else { return }
        let id = wanted.tabResourceID?.rawValue ?? ""
        if wanted.conversation?.page != nil { store.onPageTabCreated?(id, tab) } else { store.onTabCreated?(id, tab) }
    }

    /// The daemon's raw `tab-added` of a conversation tab, with no transaction: the daemon sends it
    /// as it makes the tab, and the copy carrying the create's transaction (`echoed`) and the reply
    /// (`created`) trail it (cmux-tui conversation_tabs_wire.rs, bead in the commit). Shown as it
    /// came, the store listed the daemon's tab BESIDE the provisional one until the reply, and the
    /// strip grew one in while the other closed on every Cmd-T (hq-1d 2026-10-14).
    /// Nothing on the event names its create, so it is taken for one only when that cannot be
    /// wrong in practice: the pane has exactly ONE pending create intent without a tab, its record
    /// is the same (agent session host and session, page, route), and the tab is the newest in
    /// the pane. Otherwise (two quick Cmd-T, a tab of another kind or record) the tab shows as it
    /// came and the echo or reply settles the stand-in as before.
    @MainActor static func matched(_ event: DaemonEvent, in store: DaemonStore) {
        guard case .tabAdded(let delta) = event, delta.clientTransactionID == nil, delta.entity.kind == .conversation,
              let tab = store.tabsBySurface[delta.surface],
              !store.intentLog.entries.contains(where: { $0.createdSurface == delta.surface }) else { return }
        let waiting = store.intentLog.entries.filter { entry in
            guard entry.createdSurface == nil, case .createTab(let pane, _) = entry.kind else { return false }
            return pane == delta.pane
        }
        guard waiting.count == 1, let entry = waiting.first, case .createTab(_, let provisional) = entry.kind,
              provisional.kind == .conversation, let wanted = provisional.conversation else { return }
        let asked = delta.entity.conversation
        guard wanted.agentSession?.host == asked?.agentSession?.host, wanted.agentSession?.session == asked?.agentSession?.session,
              wanted.page == asked?.page, wanted.route == asked?.route else { return }
        // The newest daemon tab of the pane (daemon surfaces count up; provisional ones live above them).
        let daemonTabs = store.pane(delta.pane)?.tabs.filter { !isProvisional(surface: $0.surface) } ?? []
        guard daemonTabs.allSatisfy({ $0.surface.rawValue <= delta.surface.rawValue }) else { return }
        store.intentLog.noteCreated(entry.transaction, surface: delta.surface)
        guard !entry.closeWhenCreated else { return }
        let id = provisional.tabResourceID?.rawValue ?? ""
        if provisional.conversation?.page != nil { store.onPageTabCreated?(id, tab) } else { store.onTabCreated?(id, tab) }
    }
}
