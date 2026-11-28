/// A pane close shown in the key's turn (plans/cmux-next/close-animation/DESIGN.md): the pane
/// leaves the shown screens, and with `layout.splitSizing` even its chain takes the sizes the close
/// leaves (`pane_close_split_changes`), in one layout. A column's only pane takes its column with it, and with
/// `layout.newColumnWidth` fitScreen the columns left share the viewport again. Nothing is sent: the
/// caller sends the close, and the daemon's tree without the pane then shows what is already shown.
///
/// A close's sizes (split ratios under `layout.splitSizing` even, column widths under
/// `layout.newColumnWidth` fitScreen) are derived, never held per split or column: the shown sizes
/// are the daemon's, then the sizes of closes that landed while others were pending
/// (`landedCloseSizes`), then each pending close in the order it was shown,
/// its sizing taken against the layout before it. So overlapping closes, in one split chain or
/// across columns, their echoes in any order and a refusal of any of them each show what the
/// closes still pending leave, and the sizes go to the daemon once, when the screen's last pending
/// close resolves (`flushLandedCloseSizes`).
extension LayoutModel {
    /// Hides `pane` from the shown screens with its chain's close sizing, in this turn.
    ///
    /// A pane with a sibling in its split tree closes this way, and so does a column's only pane
    /// when another column stays (Leo 2026-10-25: "we should never block shit on the tab
    /// animation"; the column used to wait for the daemon's tree while its emptied strip played the
    /// tab's close), and so does a pane in a column with rows (its row's tree loses it; a row it
    /// empties leaves the column). The screen's last pane leaves with
    /// the daemon's tree.
    ///
    /// - Parameter pane: The pane whose last tab (or which) closes.
    /// - Returns: The pending close, for ``settlePaneClose(_:)`` or ``cancelPaneClose(_:)``; nil when
    ///   the pane is not shown, is zoomed, or nothing stays to take its space.
    public func showPaneClose(_ pane: PaneID) -> PendingPaneClose? {
        struct Request: Encodable { var pane: PaneID, layout: ScreenLayout, sizing: PaneCloseReply.Sizing }
        guard let screen = closableScreen(pane),
              let shown = PaneCloseReply.call("pane_close_show", Request(pane: pane, layout: screen.layout, sizing: closeSizing))?.shown
        else { return nil }
        let close = PendingPaneClose(pane: pane, successor: shown.successor, transaction: .make())
        paneCloseSequence += 1
        paneCloses[pane] = PaneCloseHold(transaction: close.transaction, sequence: paneCloseSequence)
        // The sizes this close leaves supersede sent sizes the daemon has not acknowledged yet for the
        // same splits and columns (an earlier close's flush): those apply after the closes in `overlaid`
        // and would hold the chain at the older sizes until their reply. Rust names them under the sizing.
        supersedeSentRatios(Set(shown.splits))
        supersedeSentWidths(Set(shown.columns))
        showOverlaid()
        if focusedPane == pane, let successor = close.successor { focus(successor, notify: false) }
        return close
    }

    /// Whether ``showPaneClose(_:)`` would show `pane`'s close now (it changes nothing): a close
    /// that may still be rolled back (a terminal's close while the daemon's read decides) hides the
    /// pane only when the layout can show it leaving.
    public func canShowPaneClose(_ pane: PaneID) -> Bool {
        closableScreen(pane).flatMap { Self.removingSplitPane(pane, from: $0.layout) } != nil
    }

    /// `pane`'s screen, when no close of it is pending and the screen is not zoomed.
    private func closableScreen(_ pane: PaneID) -> LayoutScreen? {
        guard paneCloses[pane] == nil, let screen = screens.first(where: { $0.layout.contains(pane) }), !screen.zoomed else { return nil }
        return screen
    }

    /// The sizing settings a close reads.
    var closeSizing: PaneCloseReply.Sizing { .init(even: splitSizing == .even, fits: newColumnWidthMode == .fitScreen) }

    /// The daemon accepted the close: the next snapshot says what is true (it was asked after the
    /// close committed), with the pane or without it.
    public func settlePaneClose(_ close: PendingPaneClose) {
        paneCloses[close.pane]?.settled = true
    }

    /// The daemon refused the close: the pane and its chain's sizes come back at once; the closes
    /// still pending keep theirs, and when none is left the sizes of those that landed go out.
    public func cancelPaneClose(_ close: PendingPaneClose) {
        guard paneCloses[close.pane]?.transaction == close.transaction else { return }
        paneCloses[close.pane] = nil
        showOverlaid()
        flushLandedCloseSizes()
    }

    /// Takes back `pane`'s pending close, whoever showed it, as a refusal does: the caller shows the pane
    /// again (a rolled-back hide) or hands the close on to one shown in this same turn.
    /// - Returns: Whether a close was pending.
    @discardableResult
    public func withdrawPaneClose(_ pane: PaneID) -> Bool {
        guard let hold = paneCloses[pane] else { return false }
        cancelPaneClose(PendingPaneClose(pane: pane, successor: nil, transaction: hold.transaction))
        return true
    }

    /// Whether `pane` is hidden by a pending close.
    public func isClosing(_ pane: PaneID) -> Bool { paneCloses[pane] != nil }

    /// The holds a daemon snapshot ends: the pane left its tree (the close landed; its sizes are
    /// the landed close sizes, `noteLandedCloses`), or the close was settled and this snapshot is
    /// the truth.
    func resolvePaneCloses(in screens: [LayoutScreen]) {
        for (pane, hold) in paneCloses where hold.settled || !screens.contains(where: { $0.layout.contains(pane) }) {
            paneCloses[pane] = nil
        }
    }

    /// The pending closes, in the order they were shown.
    var orderedPaneCloses: [PaneID] {
        paneCloses.sorted { $0.value.sequence < $1.value.sequence }.map(\.key)
    }

    /// `layout` with the landed close sizes, then each pending close in order: its pane out and the
    /// sizes it leaves, its chain's even ratios and, under fit-screen, its columns' widths
    /// (``LayoutModel`` above). No call while nothing is pending or landed.
    func overlayingPaneCloses(_ layout: ScreenLayout) -> ScreenLayout {
        struct Request: Encodable { var layout: ScreenLayout, closes: [PaneID], landed: LandedCloseSizes, sizing: PaneCloseReply.Sizing }
        let closes = orderedPaneCloses.filter(layout.contains)
        guard !closes.isEmpty || !landedCloseSizes.isEmpty else { return layout }
        let request = Request(layout: layout, closes: closes, landed: landedCloseSizes, sizing: closeSizing)
        return PaneCloseReply.call("pane_close_overlay", request)?.layout ?? layout
    }

    /// Shown closes that landed (`landed` left the daemon's tree between `old` and `new`): the sizes
    /// each screen's change leaves, against the landed sizes, join them (even ratios of each landed
    /// pane's chain, and under fit-screen the column widths), one by one in show order.
    func noteLandedCloses(from old: [LayoutScreen], to new: [LayoutScreen], landed: Set<PaneID>) {
        struct Request: Encodable {
            var old, new: [PaneCloseReply.Screen], closes: [PaneID], landedPanes: [PaneID], landed: LandedCloseSizes
            var sizing: PaneCloseReply.Sizing
        }
        let old = old.filter { screen in landed.contains(where: screen.layout.contains) }
        guard !old.isEmpty else { return }
        let new = new.filter { screen in old.contains { $0.id == screen.id } }
        let request = Request(old: old.map(PaneCloseReply.Screen.init), new: new.map(PaneCloseReply.Screen.init), closes: orderedPaneCloses,
                              landedPanes: Array(landed), landed: landedCloseSizes, sizing: closeSizing)
        if let sizes = PaneCloseReply.call("pane_close_note_landed", request)?.landed { landedCloseSizes = sizes }
    }

    /// Sends the landed close sizes of every screen with no close pending, once: the daemon then has
    /// what the screen shows. A size the daemon already has, or of a split or column gone, is dropped.
    func flushLandedCloseSizes() {
        struct Request: Encodable { var screens: [ScreenLayout], closing: [PaneID], landed: LandedCloseSizes }
        guard !landedCloseSizes.isEmpty else { return }
        let request = Request(screens: daemonScreens.map(\.layout), closing: Array(paneCloses.keys), landed: landedCloseSizes)
        guard let flush = PaneCloseReply.call("pane_close_flush", request) else { return }
        landedCloseSizes = flush.landed ?? LandedCloseSizes()
        for change in flush.ratios ?? [] { setSplitRatio(change.split, ratio: change.ratio, transaction: .make(), phase: .ended) }
        for resize in flush.widths ?? [] { setColumnWidth(resize.column, width: resize.width, transaction: .make(), phase: .ended) }
    }

    /// Sends the sizing intents for the panes and columns that left between two daemon trees
    /// (Lawrence 2026-10-16, "panes should always equalize when we create and close them"): under
    /// even sizing the closed pane's same-axis chain shares its space equally again; under fit-screen
    /// the scrolling columns that fit the viewport share it after a column closes. `landed`: panes
    /// whose close this window showed; their sizes are the landed close sizes (`noteLandedCloses`).
    /// No call unless a sizing is on and a screen lost a pane.
    func applyCloseSizing(from old: [LayoutScreen], to new: [LayoutScreen], landed: Set<PaneID> = []) {
        struct Request: Encodable { var old, new: [PaneCloseReply.Screen], landed: [PaneID], sizing: PaneCloseReply.Sizing }
        let sizing = closeSizing
        let new = new.filter { screen in
            old.first { $0.id == screen.id }.map { !Set($0.layout.panes).isSubset(of: screen.layout.panes) } ?? false
        }
        guard sizing.even || sizing.fits, !new.isEmpty else { return }
        let old = old.filter { screen in new.contains { $0.id == screen.id } }
        let request = Request(old: old.map(PaneCloseReply.Screen.init), new: new.map(PaneCloseReply.Screen.init), landed: Array(landed), sizing: sizing)
        guard let sizes = PaneCloseReply.call("pane_close_sizing", request) else { return }
        applySplitSizing(sizes.ratios ?? [])
        for resize in sizes.widths ?? [] { setColumnWidth(resize.column, width: resize.width, transaction: .make(), phase: .ended) }
    }

    /// `layout` without `pane`: its sibling in its place, or, for a column's only pane, without its
    /// column, or, in a column with rows, out of its row (as cmux-tui's tree shows it after the close).
    /// Nil when `pane` is the screen's last pane.
    nonisolated static func removingSplitPane(_ pane: PaneID, from layout: ScreenLayout) -> ScreenLayout? {
        struct Request: Encodable { var pane: PaneID, layout: ScreenLayout }
        return PaneCloseReply.call("pane_close_remove", Request(pane: pane, layout: layout))?.layout
    }
}

/// One pane hidden by a pending close (``LayoutModel/showPaneClose(_:)``).
struct PaneCloseHold {
    var transaction: LayoutTransactionID
    /// The order it was shown in: a later close's sizing is taken after an earlier one's.
    var sequence: Int
    /// The daemon accepted the close: the next snapshot wins.
    var settled = false
}
