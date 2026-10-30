import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextLayout
import CmuxNextWakeups

/// The right column beside a pane as the window shows it, for ``RightColumnPlacement``: the panes
/// that start at its right edge and overlap its height, top to bottom. Only panes that take new
/// tabs count.
///
/// Every open on the right of a pane (a link, file, folder or browser tab through
/// ``LinkOpener/open(from:background:mainPane:_:)``; a subagent, side chat, Session Info session or
/// transcript session card through ``AgentTabStore/openOnRight(of:origin:open:created:finished:)``)
/// runs through ``serially(beside:_:)``: one at a time per source pane, each deciding its place from
/// the column as it is when its turn comes, after the open before it has landed. Two opens never
/// read the same column, so neither splits where the other already did (reviews of #28044 at
/// c15e0d89 and e954bd85).
@MainActor
enum RightColumn {
    /// The right column beside `source`, measured: its panes (layout pane ids) and their widths.
    static func measure(beside source: PaneController) -> RightColumnPlacement.Column {
        guard let content = source.workspace else { return .init(sourceWidth: width(of: source)) }
        let panes = panes(beside: source.layoutPaneID, in: content)
        var widths: [String: CGFloat] = [:]
        for pane in panes { widths[pane.rawValue] = content.panes[pane].flatMap(width(of:)) }
        return .init(sourceWidth: width(of: source), panes: panes.map(\.rawValue), widths: widths)
    }

    /// `pane`'s width as the window shows it, nil until it is in a window: a pane view starts at its
    /// 400 pt placeholder frame (PaneContentView) before any layout, which is no measure, so an unshown
    /// pane sets no floor and is never taken for one too narrow to split (fleet runs of #28044 at
    /// 8e520360 and caf8e69e: SideOpenStripTests' windowless pane opened its links in place).
    static func width(of pane: PaneController) -> CGFloat? {
        guard pane.view.window != nil else { return nil }
        let width = pane.view.bounds.width
        return width > 0 ? width : nil
    }

    /// The panes right of `source` in `content`, top to bottom, from the pane frames of the screen
    /// that holds `source`, active or not (``RightColumnPlacement/column(beside:frames:gap:)``),
    /// keeping those that take new tabs. Review of #28044 at bd2b918d: the active screen's frames
    /// read an empty column for a chat on a screen the person switched away from mid-open.
    static func panes(beside source: LayoutPaneID, in content: WorkspaceContentController) -> [LayoutPaneID] {
        RightColumnPlacement.column(beside: source, frames: content.layoutView.navigationFrames(ofScreenContaining: source))
            .filter { content.panes[$0]?.stripModel.showsNewTabButton == true }
    }

    /// An open's turn: it gets `done`, which it calls once its open has landed or failed.
    typealias Turn = @MainActor (_ done: @escaping @MainActor () -> Void) -> Void

    /// How long a turn holds its source when its open never reports back.
    static let turnLimit: Duration = .seconds(30)
    /// The sources with an open under way.
    private static var running: Set<LayoutPaneID> = []
    /// The opens waiting for their source, oldest first.
    private static var waiting: [LayoutPaneID: [Turn]] = [:]

    /// Runs `turn` now, or once every open already under way beside `source` has landed or failed.
    /// Returns whether it ran now (false: it waits its turn).
    @discardableResult
    static func serially(beside source: LayoutPaneID, _ turn: @escaping Turn) -> Bool {
        guard !running.contains(source) else {
            waiting[source, default: []].append(turn)
            return false
        }
        run(turn, beside: source)
        return true
    }

    /// Whether an open beside `source` is under way (for tests).
    static func isBusy(beside source: LayoutPaneID) -> Bool { running.contains(source) }

    private static func run(_ turn: Turn, beside source: LayoutPaneID) {
        running.insert(source)
        let hold = Hold(source)
        hold.backstop.schedule(after: turnLimit) { @MainActor [hold] in hold.end() }
        turn { hold.end() }
    }

    /// Ends `source`'s turn and starts the next waiting one, if any.
    fileprivate static func next(after source: LayoutPaneID) {
        running.remove(source)
        guard var queue = waiting[source], !queue.isEmpty else { waiting[source] = nil; return }
        let turn = queue.removeFirst()
        waiting[source] = queue.isEmpty ? nil : queue
        run(turn, beside: source)
    }

    /// One turn's hold on its source: it ends once, whichever comes first, its open's `done` or the backstop.
    @MainActor private final class Hold {
        let source: LayoutPaneID
        let backstop = DemandTimer(owner: "RightColumn.turn")
        private var ended = false

        init(_ source: LayoutPaneID) { self.source = source }

        func end() {
            guard !ended else { return }
            ended = true
            backstop.cancel()
            RightColumn.next(after: source)
        }
    }
}
