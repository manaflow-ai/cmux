public import CmuxNextDaemon
public import CmuxNextLayout
import CmuxNextCompat
import CmuxNextWakeups

/// A browser tab opened straight into a new split of its pane (`frontend-browser-tab-split-v1`):
/// one `new-frontend-browser-tab {pane, split}`, one daemon commit and one `pane-added` delta. The
/// old way made the tab in the source pane and moved it to a new split once the store listed it
/// (`LinkOpener.move`): two daemon round trips before the split showed, and the opening played on
/// the source pane first (Leo 2026-11-03). The split shows in the caller's turn with a stand-in tab
/// (``ProvisionalTab/browser(_:)``) in its provisional pane, as a New Tab page's split does; the
/// daemon's pane replaces it by its client-minted id. Carried from austinywang's #23032.
public struct BrowserTabSplitCommand: Sendable {
    /// The pane the split is made from.
    public let pane: CmuxNextDaemon.PaneID
    /// The side of `pane` the new pane goes.
    public let direction: SplitDirection
    /// The address the tab opens (its stand-in shows it as its title).
    public let url: String
    /// Set for Insert New at a divider: the split wraps `around` and shows its sizing instead of the even one.
    public let insertion: DividerInsertion?

    /// - Parameters:
    ///   - pane: the pane the split is made from.
    ///   - direction: the side of `pane` the new pane goes.
    ///   - url: the address the tab opens.
    public init(pane: CmuxNextDaemon.PaneID, direction: SplitDirection, url: String, insertion: DividerInsertion? = nil) {
        self.pane = pane
        self.direction = direction
        self.url = url
        self.insertion = insertion
    }

    /// Whether `daemon` opens a browser tab straight into a split; else the caller makes it in
    /// the source pane and moves it.
    @MainActor public static func isServed(by daemon: DaemonService) -> Bool {
        daemon.supports(DaemonCapability.frontendBrowserTabSplit.rawValue) && daemon.supports(DaemonCapability.splitClientKeys.rawValue)
    }

    /// Shows the split with the tab's stand-in now (the store's intent log), before any await, and the
    /// even sizing of `layout`'s chain around `shown` (the pane's layout id), as a terminal split does. The
    /// returned work sends `create` with the request's `split` and answers the daemon's surface, or
    /// nil when the person closed the new pane first (its tab closes when it arrives,
    /// CancelledCreation). A refusal takes the split and its sizing away again and rethrows.
    /// `minted` runs with the new pane's client-minted id (`pane_<32 hex>`, which the stand-in's pane and
    /// the daemon's pane both carry) before the stand-in is in the store, so before either has a page;
    /// `settled` runs with that id and the daemon's surface once a reply names it. Not on an error: a timeout or a
    /// lost connection can follow a commit whose reply is dropped, and its pane must still mount marked (review of #37733).
    @MainActor
    public func intendNow(on daemon: DaemonService, layout: LayoutModel?, shown: CmuxNextLayout.PaneID,
                          minted: (@MainActor (_ paneID: String) -> Void)? = nil,
                          settled: (@MainActor (_ paneID: String, _ surface: SurfaceID?) -> Void)? = nil)
        -> @MainActor (_ create: (ConversationTabSplit) async throws -> SurfaceID) async throws -> SurfaceID? {
        let changes = insertion?.sizing ?? layout?.splitSizingChanges(splitting: shown, axis: direction == .right ? .horizontal : .vertical) ?? []
        let sizing = layout?.showSplitSizing(changes)
        let provisional = ProvisionalPane(holding: ProvisionalTab().browser(url)).wrapping(insertion?.around)
        minted?(provisional.paneID)
        let transaction = ClientTransactionID.generate(), store = daemon.store
        store.intend(.splitPane(pane: pane, direction: direction, ratio: 0.5, provisional: provisional), transaction: transaction)
        let request = ConversationTabSplit(direction: direction, paneID: provisional.paneID,
                                           splitID: daemon.supports(DaemonCapability.splitClientSplitID.rawValue) ? provisional.splitID : nil,
                                           around: insertion?.around)
        return { create in
            let surface: SurfaceID
            do { surface = try await create(request) } catch {
                store.rejectIntent(transaction)
                if let sizing { layout?.cancelSplitSizing(sizing) }
                throw error
            }
            settled?(request.paneID, surface)
            ProvisionalTab.created(transaction, surface: surface, in: store)
            // Every event the daemon sent before the reply: the split settles there.
            if let sequence = await daemon.connection?.eventSequence() {
                store.noteSettled(transaction, at: sequence)
            } else {
                store.noteSettledAtNextSnapshot(transaction)
            }
            let cancelled = store.creations.wasCancelled(transaction)
            if let sizing { if cancelled { layout?.cancelSplitSizing(sizing) } else { layout?.commitSplitSizing(sizing) } }
            if cancelled { return nil }
            // The reply can come before the pane's events: the next open beside this pane must find the
            // daemon's pane, not the provisional one (a create aimed at it is refused), as the move did.
            return await Self.listed(surface, in: store) ? surface : nil
        }
    }

    /// Whether `store` lists the daemon's tab `surface` (its pane arrived), heard as it appears and given
    /// up after 30 s, as LinkOpener's move waits for a made tab.
    @MainActor static func listed(_ surface: SurfaceID, in store: DaemonStore) async -> Bool {
        if store.tab(surface: surface) != nil { return true }
        let wait = Task { @MainActor () -> Bool in
            for await found in ObservationStream({ _ = store.tabListRevision; return store.tab(surface: surface) != nil }) where found { return true }
            return false
        }
        let bound = DemandTimer(owner: "BrowserTabSplitCommand.listed")
        bound.schedule(after: .seconds(30)) { @MainActor in wait.cancel() }
        defer { bound.cancel() }
        return await wait.value
    }
}

/// A browser tab a caller opens straight in a new split (`PaneBrowserTabOpener.open`'s `split`).
public struct BrowserTabSplitRequest {
    /// The side of the pane the split goes.
    public let direction: SplitDirection
    /// Runs with the new tab's surface once the daemon made it, or nil when it was refused or the
    /// person closed the new pane first.
    public let finished: @MainActor (SurfaceID?) -> Void
    /// Set for Insert New at a divider (``BrowserTabSplitCommand/insertion``).
    public let insertion: DividerInsertion?
    /// An agent asked for it (the CLI, MCP or a script): its pages are marked agent-driven before
    /// they exist, so no saved password fills and the agent's URL rules hold from the first load.
    public let agentDriven: Bool

    /// - Parameters:
    ///   - direction: the side of the pane the split goes.
    ///   - insertion: Insert New at a divider's target, `around` and sizing; nil for a plain split.
    ///   - agentDriven: the CLI, MCP or a script asked for it (``agentDriven``).
    ///   - finished: runs with the new surface, or nil, once the daemon answered.
    public init(direction: SplitDirection, insertion: DividerInsertion? = nil, agentDriven: Bool = false,
                finished: @escaping @MainActor (SurfaceID?) -> Void) {
        self.direction = direction
        self.insertion = insertion
        self.agentDriven = agentDriven
        self.finished = finished
    }
}
