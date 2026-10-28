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

    /// The stand-in of a new app-rendered browser tab (`new-frontend-browser-tab`) on `engine`
    /// (`cef`, `webkit`) opening `url` in browser profile `profile`: the app shows its page in the
    /// key's turn, and the daemon's tab takes its place when the reply names it
    /// (``created(_:surface:in:)``). The daemon's `tab-added` carries no transaction, so a browser
    /// tab of the pane that arrives first is only hidden until then (``matched(_:in:)``).
    public func browser(url: String, engine: String, profile: String?) -> TabSnapshot {
        var snapshot = TabSnapshot(surface: surface, tabResourceID: ResourceID(rawValue: id), kind: .browser, title: "",
                                   url: url, browserRenderer: "frontend", browserEngine: engine)
        snapshot.browserProfileID = profile
        return snapshot
    }

    /// The stand-in of a new terminal tab (`new-tab`, Ctrl-`) whose terminal host id the client
    /// chose (`terminal-placement-env-v1`): the daemon's tab carrying `terminal` is this one
    /// (``matched(_:in:)``), never a guess.
    public func terminal(_ terminal: TerminalID, cwd: String?) -> TabSnapshot {
        TabSnapshot(surface: surface, tabResourceID: ResourceID(rawValue: id), terminalID: terminal, kind: .pty, cwd: cwd)
    }

    public static func isProvisional(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// Whether `surface` is a provisional tab's (never a daemon surface).
    public static func isProvisional(surface: SurfaceID) -> Bool { surface.rawValue > surfaceBase }

    /// A create intent's reply named the daemon's tab `surface`: from now on the provisional tab
    /// shows only while the records lack that surface, so the two never show side by side.
    @MainActor public static func created(_ transaction: ClientTransactionID, surface: SurfaceID, in store: DaemonStore) {
        guard store.intentLog.contains(transaction) else { return }
        // A guessed tab (``matched(_:in:)``) is hidden from the visible records until now.
        let guessed = store.intentLog.entries.contains { $0.transaction == transaction && $0.createdSurface == surface && !$0.createdConfirmed }
        store.intentLog.noteCreated(transaction, surface: surface)
        if store.tabsBySurface[surface] != nil || guessed, !store.overlayLifted, store.applyDepth == 0 {
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
              let provisional = createdTab(of: entry.kind), let tab = store.tabsBySurface[delta.surface] else { return }
        let paired = entry.createdConfirmed && entry.createdSurface == delta.surface // the reply named it already
        store.intentLog.noteCreated(transaction, surface: delta.surface)
        guard !paired else { return }
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
    /// Nothing on the event names its create. The daemon runs this client's requests in the
    /// order it sent them, so the tab is most likely the OLDEST pending create of the pane that
    /// has no tab yet and asks for the same record (agent session host and session, page,
    /// route), when the tab is the newest in the pane. That is a guess (a create the daemon
    /// refused, whose reply is still on its way, is older), so the tab is only hidden and the
    /// stand-in keeps showing until the echo or the reply names the tab's create; a guess is
    /// never shown and never closed. The old rule showed the tab (replacing the stand-in) when
    /// exactly one create waited, and else as it came: with two quick Cmd-T, or a Cmd-T, Cmd-W,
    /// Cmd-T, the tab showed beside the stand-in, or a tab the person closed came back
    /// (tab-spam-race).
    @MainActor static func matched(_ event: DaemonEvent, in store: DaemonStore) {
        guard case .tabAdded(let delta) = event, delta.clientTransactionID == nil else { return }
        if delta.entity.kind == .pty, let terminal = delta.entity.terminalID {
            return claimTerminal(delta.surface, terminal: terminal, in: store)
        }
        if delta.entity.kind == .browser, delta.entity.browserRenderer == "frontend" {
            return guessBrowser(delta.surface, in: delta.pane, engine: delta.entity.browserEngine, in: store)
        }
        guard delta.entity.kind == .conversation else { return }
        guess(delta.surface, in: delta.pane, asking: delta.entity.conversation, in: store)
    }

    /// The daemon's raw `tab-added` of an app-rendered browser tab (`new-frontend-browser-tab`
    /// takes no transaction): most likely the OLDEST pending browser create of the pane on the same
    /// engine, when it is the pane's newest daemon tab. As for a conversation tab (``guess``), it
    /// is only hidden, the stand-in showing, until the reply names its create.
    @MainActor private static func guessBrowser(_ surface: SurfaceID, in pane: PaneID, engine: String?, in store: DaemonStore) {
        guard store.tab(surface: surface) != nil,
              !store.intentLog.entries.contains(where: { $0.createdSurface == surface }) else { return }
        let waiting = store.intentLog.entries.first { entry in
            guard entry.createdSurface == nil, case .createTab(let target, let provisional) = entry.kind, target == pane,
                  provisional.kind == .browser, provisional.isFrontendOwned else { return false }
            return provisional.browserEngine == engine
        }
        guard let entry = waiting else { return }
        let daemonTabs = store.pane(pane)?.tabs.filter { !isProvisional(surface: $0.surface) } ?? []
        guard daemonTabs.allSatisfy({ $0.surface.rawValue <= surface.rawValue }) else { return }
        store.intentLog.noteCreated(entry.transaction, surface: surface, confirmed: false)
    }

    /// A terminal tab whose host id a pending terminal create chose (``terminal(_:cwd:)``) is that
    /// create's: the stand-in gives way to it in this apply, so the two never show side by side
    /// even when the daemon's `tab-added` beats its reply (Ctrl-`).
    @MainActor private static func claimTerminal(_ surface: SurfaceID, terminal: TerminalID, in store: DaemonStore) {
        guard let entry = store.intentLog.entries.first(where: { entry in
            guard !entry.createdConfirmed, case .createTab(_, let provisional) = entry.kind else { return false }
            return provisional.kind == .pty && provisional.terminalID == terminal
        }) else { return }
        store.intentLog.noteCreated(entry.transaction, surface: surface)
    }

    /// A create whose guessed tab was another create's left the log (the daemon refused it): the
    /// tab is guessed again for the next waiting create, so it never shows beside that create's
    /// stand-in. Runs with the overlay lifted (the records hold the tab).
    @MainActor static func reguess(_ surface: SurfaceID, in store: DaemonStore) {
        guard let tab = store.tab(surface: surface), let pane = store.index.pane(holding: tab) else { return }
        if tab.kind == .browser, tab.isFrontendOwned { return guessBrowser(surface, in: pane.handle, engine: tab.browserEngine, in: store) }
        guard tab.kind == .conversation else { return }
        guess(surface, in: pane.handle, asking: tab.snapshot.conversation, in: store)
    }

    @MainActor private static func guess(_ surface: SurfaceID, in pane: PaneID, asking asked: ConversationTabRef?, in store: DaemonStore) {
        guard store.tab(surface: surface) != nil,
              !store.intentLog.entries.contains(where: { $0.createdSurface == surface }) else { return }
        let waiting = store.intentLog.entries.first { entry in
            guard entry.createdSurface == nil, case .createTab(let target, let provisional) = entry.kind, target == pane,
                  provisional.kind == .conversation, let wanted = provisional.conversation else { return false }
            return wanted.agentSession?.host == asked?.agentSession?.host && wanted.agentSession?.session == asked?.agentSession?.session
                && wanted.page == asked?.page && wanted.route == asked?.route
        }
        guard let entry = waiting else { return }
        // The newest daemon tab of the pane (daemon surfaces count up; provisional ones live above them).
        let daemonTabs = store.pane(pane)?.tabs.filter { !isProvisional(surface: $0.surface) } ?? []
        guard daemonTabs.allSatisfy({ $0.surface.rawValue <= surface.rawValue }) else { return }
        // Hidden, with the stand-in still shown, until the echo or the reply names its create
        // (`echoed`, `created`): view state moves then, to the right tab.
        store.intentLog.noteCreated(entry.transaction, surface: surface, confirmed: false)
    }
}
