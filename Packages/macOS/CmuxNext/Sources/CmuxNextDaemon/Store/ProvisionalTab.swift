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
    }

    /// The daemon's tab of a create intent arrived carrying the intent's transaction (the event
    /// can come before the reply): the provisional tab gives way to it in this apply, and the
    /// store reports both ids (`DaemonStore.onTabCreated`, `onPageTabCreated` for a page tab).
    @MainActor static func echoed(_ event: DaemonEvent, transaction: ClientTransactionID, in store: DaemonStore) {
        guard case .tabAdded(let delta) = event,
              let entry = store.intentLog.entries.first(where: { $0.transaction == transaction }),
              entry.createdSurface != delta.surface, // `matched` paired it already
              case .createTab(_, let provisional) = entry.kind, let tab = store.tabsBySurface[delta.surface] else { return }
        store.intentLog.noteCreated(transaction, surface: delta.surface)
        let id = provisional.tabResourceID?.rawValue ?? ""
        if provisional.conversation?.page != nil { store.onPageTabCreated?(id, tab) } else { store.onTabCreated?(id, tab) }
    }

    /// The daemon's raw `tab-added` of a conversation tab, with no transaction: the daemon sends it
    /// as it makes the tab, and the copy carrying the create's transaction (`echoed`) and the reply
    /// (`created`) trail it. Shown as it came, the store listed the daemon's tab BESIDE the
    /// provisional one until the reply, and the strip grew one in while the other closed on every
    /// Cmd-T (hq-1d 2026-10-14). The tab is the one a pending create intent in the same pane asked
    /// for when it is the same conversation tab (same agent session host and session, same page
    /// and route): the oldest such intent that has no tab yet takes it, so two quick Cmd-T pair
    /// in order, and a tab of another kind or record never takes a provisional tab's place.
    @MainActor static func matched(_ event: DaemonEvent, in store: DaemonStore) {
        guard case .tabAdded(let delta) = event, delta.clientTransactionID == nil, delta.entity.kind == .conversation,
              let tab = store.tabsBySurface[delta.surface],
              !store.intentLog.entries.contains(where: { $0.createdSurface == delta.surface }) else { return }
        let asked = delta.entity.conversation
        guard let entry = store.intentLog.entries.first(where: { entry in
            guard entry.createdSurface == nil, case .createTab(let pane, let provisional) = entry.kind, pane == delta.pane,
                  provisional.kind == .conversation, let wanted = provisional.conversation else { return false }
            return wanted.agentSession?.host == asked?.agentSession?.host && wanted.agentSession?.session == asked?.agentSession?.session
                && wanted.page == asked?.page && wanted.route == asked?.route
        }), case .createTab(_, let provisional) = entry.kind else { return }
        store.intentLog.noteCreated(entry.transaction, surface: delta.surface)
        let id = provisional.tabResourceID?.rawValue ?? ""
        if provisional.conversation?.page != nil { store.onPageTabCreated?(id, tab) } else { store.onTabCreated?(id, tab) }
    }
}
