/// A pane close shown in the key's turn (plans/cmux-next/close-animation/DESIGN.md): the pane
/// leaves the shown screens, and with `layout.splitSizing` even its chain takes the sizes the close
/// leaves (`CloseSizing`), in one layout. A column's only pane takes its column with it, and with
/// `layout.newColumnWidth` fitScreen the columns left share the viewport again. Nothing is sent: the
/// caller sends the close, and the daemon's tree without the pane then shows what is already shown.
///
/// A close's sizes (split ratios under `layout.splitSizing` even, column widths under
/// `layout.newColumnWidth` fitScreen) are derived, never held per split or column: the shown sizes
/// are the daemon's, then the sizes of closes that landed while others were pending
/// (`landedCloseRatios`, `landedCloseWidths`), then each pending close in the order it was shown,
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
        guard let (_, shown) = paneCloseShown(pane) else { return nil }
        let close = PendingPaneClose(pane: pane, successor: shown.successor.map { PaneID($0) }, transaction: .make())
        paneCloseSequence += 1
        paneCloses[pane] = PaneCloseHold(transaction: close.transaction, sequence: paneCloseSequence)
        // The sizes this close leaves supersede sent sizes the daemon has not acknowledged yet for the
        // same splits and columns (an earlier close's flush): those apply after the closes in `overlaid`
        // and would hold the chain at the older sizes until their reply.
        supersedeSentRatios(Set(shown.splits.map { SplitID($0) }))
        supersedeSentWidths(Set(shown.columns.map { ColumnID($0) }))
        showOverlaid()
        if focusedPane == pane, let successor = close.successor { focus(successor, notify: false) }
        return close
    }

    /// Whether ``showPaneClose(_:)`` would show `pane`'s close now (it changes nothing): a close
    /// that may still be rolled back (a terminal's close while the daemon's read decides) hides the
    /// pane only when the layout can show it leaving.
    public func canShowPaneClose(_ pane: PaneID) -> Bool { paneCloseShown(pane) != nil }

    /// `pane`'s screen and what its close shows (Rust `pane_close_show`), when its close can be shown.
    private func paneCloseShown(_ pane: PaneID) -> (screen: LayoutScreen, shown: PaneCloseRules.Shown)? {
        guard paneCloses[pane] == nil, let screen = screens.first(where: { $0.layout.contains(pane) }), !screen.zoomed else { return nil }
        struct Request: Encodable { var pane: String, layout: PaneCloseRules.Wire, sizing: PaneCloseRules.Sizing }
        struct Reply: Decodable { var shown: PaneCloseRules.Shown? }
        let reply: Reply? = PaneCloseRules.ask("pane_close_show", Request(pane: pane.rawValue, layout: .init(screen.layout), sizing: closeSizing))
        return reply?.shown.map { (screen, $0) }
    }

    /// The sizing policy the close rules take: `layout.splitSizing` even, `layout.newColumnWidth` fitScreen.
    var closeSizing: PaneCloseRules.Sizing {
        PaneCloseRules.Sizing(even: splitSizing == .even, fits: newColumnWidthMode == .fitScreen)
    }

    /// The landed close sizes, as the close rules take them.
    var landedCloseSizes: PaneCloseRules.Landed {
        get { PaneCloseRules.Landed(ratios: landedCloseRatios, widths: landedCloseWidths) }
        set {
            landedCloseRatios = newValue.splitRatios
            landedCloseWidths = newValue.columnWidths
        }
    }

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
    /// (``LayoutModel`` above; Rust `pane_close_overlay`). Unchanged when the reducer does not answer.
    func overlayingPaneCloses(_ layout: ScreenLayout) -> ScreenLayout {
        guard !paneCloses.isEmpty || !landedCloseRatios.isEmpty || !landedCloseWidths.isEmpty else { return layout }
        struct Request: Encodable {
            var layout: PaneCloseRules.Wire, closes: [String], landed: PaneCloseRules.Landed, sizing: PaneCloseRules.Sizing
        }
        struct Reply: Decodable { var layout: PaneCloseRules.Wire }
        let reply: Reply? = PaneCloseRules.ask("pane_close_overlay", Request(layout: .init(layout), closes: orderedPaneCloses.map(\.rawValue),
                                                                            landed: landedCloseSizes, sizing: closeSizing))
        return reply?.layout.layout ?? layout
    }

    /// Shown closes that landed (`landed` left the daemon's tree between `old` and `new`): the sizes
    /// each screen's change leaves, against the landed sizes, join them (even ratios of each landed
    /// pane's chain, and under fit-screen the column widths; Rust `pane_close_note_landed`).
    func noteLandedCloses(from old: [LayoutScreen], to new: [LayoutScreen], landed: Set<PaneID>) {
        guard !landed.isEmpty else { return }
        struct Request: Encodable {
            var old: [PaneCloseRules.Screen], new: [PaneCloseRules.Screen], closes: [String], landedPanes: [String]
            var landed: PaneCloseRules.Landed, sizing: PaneCloseRules.Sizing
        }
        struct Reply: Decodable { var landed: PaneCloseRules.Landed }
        let request = Request(old: old.map(PaneCloseRules.Screen.init), new: new.map(PaneCloseRules.Screen.init),
                              closes: orderedPaneCloses.map(\.rawValue), landedPanes: landed.map(\.rawValue).sorted(),
                              landed: landedCloseSizes, sizing: closeSizing)
        if let reply: Reply = PaneCloseRules.ask("pane_close_note_landed", request) { landedCloseSizes = reply.landed }
    }

    /// Sends the landed close sizes of every screen with no close pending, once: the daemon then has
    /// what the screen shows. A size the daemon already has, or of a split or column gone, is dropped
    /// (Rust `pane_close_flush`).
    func flushLandedCloseSizes() {
        guard !landedCloseWidths.isEmpty || !landedCloseRatios.isEmpty else { return }
        struct Request: Encodable { var screens: [PaneCloseRules.Wire], closing: [String], landed: PaneCloseRules.Landed }
        let request = Request(screens: daemonScreens.map { .init($0.layout) }, closing: paneCloses.keys.map(\.rawValue).sorted(),
                              landed: landedCloseSizes)
        guard let flush: PaneCloseRules.Flush = PaneCloseRules.ask("pane_close_flush", request) else { return }
        landedCloseSizes = flush.landed
        for change in flush.ratios { setSplitRatio(SplitID(change.split), ratio: change.ratio, transaction: .make(), phase: .ended) }
        for resize in flush.widths { setColumnWidth(ColumnID(resize.column), width: resize.width, transaction: .make(), phase: .ended) }
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

extension LayoutModel {
    /// `layout` without `pane`: its sibling in its place, or, for a column's only pane, without its
    /// column, or, in a column with rows, out of its row (Rust `pane_close_remove`). Nil when `pane`
    /// is the screen's last pane.
    static func removingSplitPane(_ pane: PaneID, from layout: ScreenLayout) -> ScreenLayout? {
        struct Request: Encodable { var pane: String, layout: PaneCloseRules.Wire }
        struct Reply: Decodable { var layout: PaneCloseRules.Wire? }
        let reply: Reply? = PaneCloseRules.ask("pane_close_remove", Request(pane: pane.rawValue, layout: .init(layout)))
        return reply?.layout?.layout
    }

    /// The pane that takes the focus from `pane` (close-focus.md; Rust `pane_close_successor`).
    static func successor(of pane: PaneID, in layout: ScreenLayout) -> PaneID? {
        struct Request: Encodable { var pane: String, layout: PaneCloseRules.Wire }
        struct Reply: Decodable { var successor: String? }
        let reply: Reply? = PaneCloseRules.ask("pane_close_successor", Request(pane: pane.rawValue, layout: .init(layout)))
        return reply?.successor.map { PaneID($0) }
    }
}
