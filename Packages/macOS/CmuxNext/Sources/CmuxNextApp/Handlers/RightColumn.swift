import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextLayout
import CmuxNextWakeups

/// The right column beside a pane as the window shows it, for ``RightColumnPlacement``: the panes
/// that start at its right edge and overlap its height, top to bottom. Only panes that take new
/// tabs count.
@MainActor
enum RightColumn {
    /// The right column beside `source`, measured: its panes (layout pane ids) and their widths.
    static func measure(beside source: PaneController) -> RightColumnPlacement.Column {
        guard let content = source.workspace else { return .init(sourceWidth: source.view.bounds.width) }
        let panes = panes(beside: source.layoutPaneID, in: content)
        var widths: [String: CGFloat] = [:]
        for pane in panes { widths[pane.rawValue] = content.panes[realPane(pane)]?.view.bounds.width }
        return .init(sourceWidth: source.view.bounds.width, panes: panes.map(\.rawValue), widths: widths)
    }

    /// Lower splits under way, by the right pane they split: until a split's move lands, its column is
    /// read as two panes, so an open started meanwhile is a tab there instead of a second split below the
    /// same pane (review of #28044 at c15e0d89: two links opened together made three panes on the right).
    private static var pendingBelow: [LayoutPaneID: Int] = [:]
    /// How long a reservation holds when its move never reports back.
    static let reservationLimit: Duration = .seconds(30)

    /// Reserves the lower split of right pane `pane` for one open; call the returned function when its
    /// move lands or fails (it is safe to call more than once). A backstop ends it after ``reservationLimit``.
    static func reserveBelow(_ pane: LayoutPaneID) -> @MainActor () -> Void {
        pendingBelow[pane, default: 0] += 1
        let reservation = Reservation(pane)
        reservation.backstop.schedule(after: reservationLimit) { @MainActor [reservation] in reservation.end() }
        return { reservation.end() }
    }

    /// One reservation: its count goes once, whichever comes first, its release or its backstop.
    @MainActor private final class Reservation {
        let pane: LayoutPaneID
        let backstop = DemandTimer(owner: "RightColumn.reserveBelow")
        private var ended = false

        init(_ pane: LayoutPaneID) { self.pane = pane }

        func end() {
            guard !ended else { return }
            ended = true
            backstop.cancel()
            let left = (RightColumn.pendingBelow[pane] ?? 1) - 1
            RightColumn.pendingBelow[pane] = left > 0 ? left : nil
        }
    }

    /// `column` with the lower pane of each split under way: its right pane, then a stand-in for the pane
    /// still moving in, so ``RightColumnPlacement`` sees the column as full.
    static func withPendingSplits(_ column: [LayoutPaneID]) -> [LayoutPaneID] {
        guard column.count == 1, let pane = column.first, pendingBelow[pane] != nil else { return column }
        return [pane, LayoutPaneID("pending-below:\(pane.rawValue)")]
    }

    /// The pane a tab goes to when placement picks `id`: a pending lower split's stand-in is still its
    /// right pane, where the moving tab sits until its split lands.
    static func realPane(_ id: LayoutPaneID) -> LayoutPaneID {
        id.rawValue.hasPrefix("pending-below:") ? LayoutPaneID(String(id.rawValue.dropFirst("pending-below:".count))) : id
    }

    /// The panes right of `source` in `content`, top to bottom, from the pane frames of the screen
    /// that holds `source`, active or not (``RightColumnPlacement/column(beside:frames:gap:)``),
    /// keeping those that take new tabs. Review of #28044 at bd2b918d: the active screen's frames
    /// read an empty column for a chat on a screen the person switched away from mid-open.
    static func panes(beside source: LayoutPaneID, in content: WorkspaceContentController) -> [LayoutPaneID] {
        withPendingSplits(RightColumnPlacement.column(beside: source, frames: content.layoutView.navigationFrames(ofScreenContaining: source))
            .filter { content.panes[$0]?.stripModel.showsNewTabButton == true })
    }
}
