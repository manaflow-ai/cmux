import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Leo 2026-11-06, the motion targets: "every affected element moves together from its start to its end position,
/// monotonically, with no overshoot to a wrong position and no snap or pop-in after the animation ends." This suite
/// checks them (``MotionTargetTrace``) for a pane's tab strip: a tab moved to another slot, every tab between sliding
/// over, and a tab closed in the middle of the strip.
///
/// A strip change has no manual frame clock: the strip writes each tab's target at once and adds an additive Core
/// Animation tween from where it showed (`TabStripMove`, 200 ms on `tabMove`), which the render server draws. So each
/// frame is sampled from the tab's layer at a fixed media time, the move's begin time plus k/120 s
/// (`MotionPath.value(at:)`, the render server's own evaluation of every move on the layer), not at real time, and the
/// samples do not depend on how busy the runner is. A tab's shown x is its layer's left edge in the strip's content;
/// the strip itself does not move, so every sample has `containerStep: 0`. After the last frame one more layout pass
/// runs, and each tab's model x then is its rest.
///
/// The strip animates only in a window on a screen (`TabStripView.stripMove`: `Motion.canAnimate` refuses a window
/// out of sight, where Core Animation would never end the move), so these cases need a display worker (`--display`);
/// without a screen they are skipped, as `TabCloseInstantTests` is.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct TabMoveMotionTargetTests {
    static func ids(_ count: Int) -> [TabID] { (0..<count).map { TabID("tab\($0)") } }

    /// tab0 moves from the first slot to the last: tab0 slides right over three slots, tab1 to tab3 one slot left.
    @Test(.enabled("the strip animates only in a window on a screen") { await TabCloseInstantTests.hasDisplay() })
    func aTabMovedToTheEndSlidesWithItsNeighbours() throws {
        let trace = try Self.trace(count: 4) { tabs in
            let moved = tabs.removeFirst()
            tabs.append(moved)
        }
        Self.report("tab move, first to last", trace)
        #expect(trace.violations.isEmpty, "\(trace.violations.count) frames break a motion target: \(trace.violations.prefix(4))")
    }

    /// tab2 moves one slot left (a move-left key): tab2 and tab1 swap places on one tween.
    @Test(.enabled("the strip animates only in a window on a screen") { await TabCloseInstantTests.hasDisplay() })
    func aTabMovedOneSlotLeftSwapsWithItsNeighbour() throws {
        let trace = try Self.trace(count: 4) { tabs in
            tabs.swapAt(1, 2)
        }
        Self.report("tab move, one slot left", trace)
        #expect(trace.violations.isEmpty, "\(trace.violations.count) frames break a motion target: \(trace.violations.prefix(4))")
    }

    /// tab1 closes. A tab that is not its pane's last closes in one frame (Lawrence 2026-10-19, msg 2833:
    /// "Close animation only for the whole pane (last tab) and the whole window; tab close instant";
    /// `TabCloseInstantTests`): the tabs left are at their new places in the close's own frame, with no tween. That one
    /// step is the settled design, so a jump at frame 1 is the close itself and is not counted; every other target holds:
    /// nothing moves after that frame, nothing moves away from its rest, and nothing moves after the landing.
    @Test(.enabled("the strip animates only in a window on a screen") { await TabCloseInstantTests.hasDisplay() })
    func aTabClosedInTheMiddleLeavesItsNeighboursAtRestFromItsFrame() throws {
        let trace = try Self.trace(count: 4, startsMove: false) { tabs in
            tabs.remove(at: 1)
        }
        Self.report("tab close, middle", trace)
        let broken = trace.violations.filter { !($0.kind == .jump && $0.frame == 1) }
        #expect(broken.isEmpty, "\(broken.count) frames break a motion target: \(broken.prefix(4))")
    }

    // MARK: - The rig

    /// A strip of `count` tabs in a window on a screen, with Reduce Motion off; `change` edits the model's tabs and the
    /// strip syncs, as the App's model echo does. Records every tab still shown after the change: its x before the
    /// change (frame 0), then at the move's begin plus k/120 s to its end and one frame past it, then its rest after one
    /// more layout pass. `startsMove`: the change starts a strip move (a reorder); false (a close) samples the 200 ms
    /// the move would have taken from the change on.
    static func trace(count: Int, startsMove: Bool = true, _ change: (inout [TabItem]) -> Void) throws -> MotionTargetTrace {
        let tabs = Self.ids(count).enumerated().map { TabItem(id: $0.element, title: "Tab \($0.offset)") }
        let model = TabStripModel(tabs: tabs, selectedID: tabs[0].id)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let strip = TabStripView(model: model)
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
        window.contentView = strip
        window.orderFrontRegardless()
        try #require(window.screen != nil, "SETUP: the strip's window is on no screen")
        strip.layoutSubtreeIfNeeded()
        // Synchronous from here to the reset: the override is process-wide.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.tabs.animatesMovement, "SETUP: animation speed is off on this host")
        try #require(Self.moveKeys(strip).isEmpty, "SETUP: a strip move runs before the change")

        let before = CACurrentMediaTime()
        let start = Dictionary(strip.cells.map { ($0.key, Self.shownX($0.value, at: before)) }, uniquingKeysWith: { first, _ in first })
        var next = model.tabs
        change(&next)
        model.tabs = next
        strip.sync(fromModel: true)

        let shown = next.map(\.id).filter { strip.cells[$0] != nil }
        try #require(shown.count == next.count, "the strip shows \(shown.count) of the model's \(next.count) tabs")
        let cells: [(TabID, TabCell)] = try shown.map { id in
            let cell = try #require(strip.cells[id])
            return (id, cell)
        }
        let begin: CFTimeInterval
        let end: CFTimeInterval
        if startsMove {
            try #require(!Self.moveKeys(strip).isEmpty, "the change started no strip move")
            begin = try #require(Self.moveBegin(cells.map(\.1)), "the strip move has no begin time")
            end = cells.compactMap { _, cell in
                [MotionPath(cell.layer, "position").end, MotionPath(cell.layer, "bounds.size").end].compactMap { $0 }.max()
            }.max() ?? begin
            try #require(end - begin > 3.0 / 120, "the move did not animate (\(end - begin) s)")
        } else {
            #expect(Self.moveKeys(strip).isEmpty, "the close started strip moves: \(Self.moveKeys(strip))")
            begin = CACurrentMediaTime()
            end = begin + (MotionMove.tween(.tabMove, in: Motion.tabs)?.duration ?? 0.2)
        }

        var trace = MotionTargetTrace()
        for (id, _) in cells {
            if let x = start[id] { trace.record(id.rawValue, x, containerStep: 0) }
        }
        let frames = Int(((end - begin) * 120).rounded(.up)) + 1
        for k in 0...frames {
            let time = begin + Double(k) / 120
            for (id, cell) in cells { trace.record(id.rawValue, Self.shownX(cell, at: time), containerStep: 0) }
        }
        // The landing, then one more layout pass: every tab's model geometry is where it rests.
        strip.needsLayout = true
        strip.layoutSubtreeIfNeeded()
        for (id, cell) in cells { trace.settle(id.rawValue, cell.layer.frame.minX) }
        return trace
    }

    /// The left edge `cell` shows at media time `time`, in the strip's content: its model geometry plus every strip move
    /// on its layer, as the render server draws it.
    static func shownX(_ cell: TabCell, at time: CFTimeInterval) -> CGFloat {
        let layer = cell.layer
        let position = MotionPath(layer, "position").value(at: time)
        let size = MotionPath(layer, "bounds.size").value(at: time)
        return position.x - layer.anchorPoint.x * size.x
    }

    /// The media time the strip move on `cells` begins (every animation of one move shares it, `TabStripMove.begin`).
    static func moveBegin(_ cells: [TabCell]) -> CFTimeInterval? {
        cells.flatMap { cell in
            (cell.layer.animationKeys() ?? []).filter { $0.hasPrefix(TabStripMove.keyPrefix) }.compactMap { key in
                cell.layer.animation(forKey: key).map { cell.layer.convertTime($0.beginTime, to: nil) }
            }
        }.min()
    }

    static func moveKeys(_ strip: TabStripView) -> [String] {
        strip.cells.values.flatMap { ($0.layer.animationKeys() ?? []).filter { $0.hasPrefix(TabStripMove.keyPrefix) } }
    }

    static func report(_ name: String, _ trace: MotionTargetTrace) {
        print("motion-trace: \(name): \(trace.summary)")
    }
}
