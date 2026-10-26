public import CmuxNextDaemon

/// The daemon side of a person's new browser tab (`new-frontend-browser-tab`, PL-cef-tab): a
/// stand-in tab is in the pane's store in the caller's turn, so the app shows it, selected and with
/// its page, in the key's frame (target < 10 ms, both engines), and the request runs behind it.
///
/// `new-frontend-browser-tab` takes no transaction: the daemon's `tab-added` that comes before
/// its reply is hidden by a guess (``ProvisionalTab/matched(_:in:)``) until the reply names it.
/// On the reply the daemon's tab takes the stand-in's place in one apply
/// (``ProvisionalTab/created(_:surface:in:)``); in that same turn `handOver` moves whatever the
/// app made for the stand-in (its page) to the daemon's tab, before any view sees the swap. A
/// refusal rejects the intent (the stand-in goes); a stand-in closed first is a cancelled creation
/// (`CancelledCreation`: the daemon's tab closes once named).
public struct NewBrowserTabCommand: Sendable {
    /// The pane the tab goes in.
    public let pane: PaneID
    /// The address the tab opens.
    public let url: String
    /// Its engine tag (`cef`, `webkit`).
    public let engine: String
    /// Its browser profile id; nil is `default`.
    public let profile: String?

    /// - Parameters:
    ///   - pane: the pane the new tab goes in.
    ///   - url: the address it opens.
    ///   - engine: its engine tag (`cef`, `webkit`).
    ///   - profile: its browser profile id, nil for `default`.
    public init(pane: PaneID, url: String, engine: String, profile: String?) {
        self.pane = pane
        self.url = url
        self.engine = engine
        self.profile = profile
    }

    /// The stand-in tab, and the work that creates the daemon's tab.
    public struct Pending {
        /// The stand-in's tab id (`TabModel.id`), shown in the pane when ``NewBrowserTabCommand/intendNow(on:create:)`` returns.
        public let tab: String
        /// Its surface.
        public let surface: SurfaceID
        /// Runs the create; returns the daemon's tab. `handOver` runs in the turn the daemon's tab
        /// takes the stand-in's place (not for a cancelled stand-in). Throws the create's error
        /// (the stand-in is gone then) or ``NewBrowserTabCancelled``.
        public let send: @MainActor (_ handOver: @MainActor (SurfaceID) -> Void) async throws -> SurfaceID
    }

    /// Shows the stand-in now (the store's intent log), before any await. `create` sends
    /// `new-frontend-browser-tab` and returns the daemon's surface.
    @MainActor
    public func intendNow(on daemon: DaemonService, create: @escaping @MainActor () async throws -> SurfaceID) -> Pending {
        let provisional = ProvisionalTab(), transaction = ClientTransactionID.generate(), store = daemon.store
        store.intend(.createTab(pane: pane, provisional: provisional.browser(url: url, engine: engine, profile: profile)), transaction: transaction)
        return Pending(tab: provisional.id, surface: provisional.surface) { handOver in
            let surface: SurfaceID
            do { surface = try await create() } catch {
                store.rejectIntent(transaction)
                throw error
            }
            // The records hold the daemon's tab once the store applied what came before the reply.
            let sequence = await daemon.connection?.eventSequence()
            await store.applied(through: sequence)
            let cancelled = store.creations.wasCancelled(transaction)
            ProvisionalTab.created(transaction, surface: surface, in: store)
            if !cancelled, store.tab(surface: surface) != nil { handOver(surface) }
            if let sequence { store.noteSettled(transaction, at: sequence) } else { store.noteSettledAtNextSnapshot(transaction) }
            if cancelled { throw NewBrowserTabCancelled() }
            return surface
        }
    }
}

/// An optimistic new browser tab the person closed before the daemon made it (CancelledCreation).
public struct NewBrowserTabCancelled: Error, CustomStringConvertible {
    public var description: String { "the tab closed before the daemon made it" }
}
