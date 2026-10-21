import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextLayout

/// A browser tab opened straight into a new split of its pane (`frontend-browser-tab-split-v1`):
/// one `new-frontend-browser-tab {pane, split}`, one daemon commit and one `pane-added` delta. The
/// old way made the tab in the source pane and moved it to a new split once the store listed it
/// (`LinkOpener.move`), so a link opened to the right showed as another tab of the chat's pane,
/// then slid into its split (user report 2026-10-20). The split shows now, in this frame, with a
/// stand-in tab (``ProvisionalTab/browser(_:)``) in its provisional pane, as a New Tab page's split
/// does (`NewTabPage.split`); the daemon's pane replaces it by its client-minted id.
@MainActor struct PaneBrowserTabSplit {
    private let daemon: DaemonService
    private let layoutModel: LayoutModel?
    private let provisional: ProvisionalPane
    private let direction: SplitDirection
    private let transaction: ClientTransactionID
    private let sizing: PendingSplitSizing?

    /// Whether `daemon` opens a browser tab straight into a split; else the caller makes it in
    /// the source pane and moves it.
    static func isServed(by daemon: DaemonService) -> Bool {
        daemon.supports(DaemonCapabilities.shared.frontendBrowserTabSplit)
    }

    /// Shows the split of `source` on `direction` with `url`'s stand-in tab, and its chain's even
    /// sizing (as a terminal split, PaneHandlers.split), now; nothing is sent yet.
    init(showing url: String, from source: PaneController, direction: SplitDirection) {
        let layoutModel = source.workspace?.layoutModel, provisional = ProvisionalPane(holding: ProvisionalTab().browser(url))
        let transaction = ClientTransactionID.generate()
        let changes = layoutModel?.splitSizingChanges(splitting: source.layoutPaneID, axis: direction == .right ? .horizontal : .vertical) ?? []
        daemon = source.daemon
        self.layoutModel = layoutModel
        self.direction = direction
        self.provisional = provisional
        self.transaction = transaction
        sizing = layoutModel?.showSplitSizing(changes)
        source.daemon.store.intend(.splitPane(pane: source.pane.handle, direction: direction, ratio: 0.5, provisional: provisional),
                                   transaction: transaction)
        // The provisional pane is in the store: the window lays it out and mounts it in this turn,
        // so the split draws in the click's frame (instant-new-surfaces).
        BenchSpans.measure("split.layout") { source.workspace?.applyCurrent() }
    }

    /// Sends the tab's create through `make` with the request's `split`. The new surface, or nil
    /// when the person closed the new pane first (its tab closes when it arrives, CancelledCreation).
    /// A refusal takes the split away again and rethrows.
    func open(_ make: (ConversationTabSplit) async throws -> SurfaceID) async throws -> SurfaceID? {
        let surface: SurfaceID
        do {
            surface = try await make(request)
        } catch {
            failed()
            throw error
        }
        return await created(surface) ? surface : nil
    }

    /// The request's `split`: the side and the provisional pane's client-minted ids.
    var request: ConversationTabSplit {
        ConversationTabSplit(direction: direction, paneID: provisional.paneID,
                             splitID: daemon.supports(DaemonCapabilities.shared.splitClientSplitID) ? provisional.splitID : nil)
    }

    /// The daemon made the tab on `surface`: the stand-in gives way to it once the daemon's pane is
    /// placed, and the sizing goes to the daemon. False when the person closed the pane first.
    private func created(_ surface: SurfaceID) async -> Bool {
        let store = daemon.store
        ProvisionalTab.created(transaction, surface: surface, in: store)
        // Every event the daemon sent before the reply: the split settles there.
        if let connection = daemon.connection, let sequence = await connection.eventSequence() {
            store.noteSettled(transaction, at: sequence)
        } else {
            store.noteSettledAtNextSnapshot(transaction)
        }
        if let sizing { layoutModel?.commitSplitSizing(sizing) }
        return !store.creations.wasCancelled(transaction)
    }

    /// The tab was refused: the split and its sizing go in the same turn.
    private func failed() {
        daemon.store.rejectIntent(transaction)
        if let sizing { layoutModel?.cancelSplitSizing(sizing) }
    }
}
