import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Lawrence, cmux-ad m49 (2026-11-07): "A: animate the tab strip". A tab that is not its pane's last (close case A,
/// plans/cmux-next/close-animation/DESIGN.md) leaves on the strip's close tween: it shrinks out with its left edge on
/// the previous tab, and the tabs left slide to their new places on the same clock. The pane, its content host and
/// the split do not move; Reduce Motion shows the final strip in the close's frame; a second close during the slide
/// starts from where every tab shows (no jump). Cases B/C/D (a pane's or a workspace's last tab) are not a strip close.
///
/// The seam: the strip's frames per 120 Hz tick after a close. A strip move is an additive Core Animation tween the
/// render server draws (`TabStripMove`), so each tick is read from the cell's layer at the move's begin plus k/120 s
/// (`MotionPath.value(at:)`, the render server's own evaluation), not at real time. The strip lives in the app's pane
/// content (`PaneContentView`) in no window: `Motion.canAnimate` lets a view in no window animate as one on screen
/// does, so these run on any worker.
@MainActor @Suite(.serialized) struct TabCloseMotionTests {
    struct Rig {
        let model: TabStripModel
        let pane: PaneContentView
        var strip: TabStripView { pane.stripView }
    }

    static func rig(_ tabs: [TabItem], selected: TabID) -> Rig {
        let reveal = LaunchReveal()
        reveal.markAllReady()
        let model = TabStripModel(tabs: tabs, selectedID: selected)
        let pane = PaneContentView(stripModel: model, reveal: reveal)
        pane.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        pane.stripView.sync(fromModel: true)
        pane.layoutSubtreeIfNeeded()
        return Rig(model: model, pane: pane)
    }

    static func tabs(_ count: Int, pinned: Int = 0) -> [TabItem] {
        (0..<count).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)", isPinned: $0 < pinned) }
    }

    static func moveKeys(_ strip: TabStripView) -> [String] {
        strip.cells.values.flatMap { ($0.layer.animationKeys() ?? []).filter { $0.hasPrefix(TabStripMove.keyPrefix) } }
    }

    /// What `cell` shows at media time `time`: its left edge and width, its model geometry plus every move on its layer.
    static func shown(_ cell: TabCell, at time: CFTimeInterval) -> (x: CGFloat, width: CGFloat) {
        let layer = cell.layer
        let position = MotionPath(layer, "position").value(at: time)
        let size = MotionPath(layer, "bounds.size").value(at: time)
        return (position.x - layer.anchorPoint.x * size.x, size.x)
    }

    /// The media time the strip move on `cells` begins (every animation of one move shares it).
    static func moveBegin(_ cells: [TabCell]) -> CFTimeInterval? {
        cells.flatMap { cell in
            (cell.layer.animationKeys() ?? []).filter { $0.hasPrefix(TabStripMove.keyPrefix) }.compactMap { key in
                cell.layer.animation(forKey: key).map { cell.layer.convertTime($0.beginTime, to: nil) }
            }
        }.min()
    }

    /// The pane's own geometry: its frame, its content host's and its strip's. A strip close changes none of them.
    static func paneGeometry(_ pane: PaneContentView) -> [CGRect] {
        [pane.frame, pane.contentHost.frame, pane.stripView.frame]
    }

    /// Runs with Reduce Motion `reduce` and `ui.animations.newTab` (the strip's structural motion switch, on by
    /// default) on; restores both.
    static func withMotion(reduce: Bool, _ body: () throws -> Void) throws {
        Motion.reduceMotionOverride = reduce
        defer { Motion.reduceMotionOverride = nil }
        let enabledAnimations = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newTab)
        defer { DesignSettings.shared.enabledAnimations = enabledAnimations }
        try body()
    }

    enum Case: String, CaseIterable, CustomTestStringConvertible {
        /// The selected middle tab closes; the selection moves to its right neighbour in the same sync.
        case active
        /// A middle tab that is not selected closes.
        case inactive
        /// Chrome's closing mode (a mouse close under a still pointer): the tabs keep their widths, the ones right of
        /// the closed tab slide left into its room.
        case closingMode
        /// The first of two pinned tabs closes: the other pinned tab and the unpinned ones slide left.
        case pinned

        var testDescription: String { rawValue }
    }

    /// Close case A: the closed tab shrinks out and the tabs right of it slide, every 120 Hz tick showing a place
    /// between where they were and where they rest; the pane's geometry stays the same in every tick.
    @Test(arguments: Case.allCases)
    func aTabThatIsNotTheLastSlidesOutOnTheStrip(_ which: Case) throws {
        try Self.withMotion(reduce: false) {
            try #require(Motion.tabs.animatesMovement, "SETUP: animation speed is off on this host")
            let pinned = which == .pinned ? 2 : 0
            let closed = which == .pinned ? TabID("tab0") : TabID("tab1")
            let selected = which == .active ? closed : TabID(which == .pinned ? "tab2" : "tab0")
            let rig = Self.rig(Self.tabs(5, pinned: pinned), selected: selected)
            let strip = rig.strip
            if which == .closingMode { strip.closingModeWidth = strip.result.standardWidth }
            try #require(Self.moveKeys(strip).isEmpty, "SETUP: a strip move runs before the close")
            let geometry = Self.paneGeometry(rig.pane)
            let now = CACurrentMediaTime()
            let start = Dictionary(uniqueKeysWithValues: strip.cells.map { ($0.key, Self.shown($0.value, at: now)) })

            let index = try #require(rig.model.tabs.firstIndex { $0.id == closed })
            if which == .active { rig.model.selectedID = rig.model.tabs[index + 1].id }
            rig.model.tabs.remove(at: index)
            strip.sync(fromModel: true)
            rig.pane.layoutSubtreeIfNeeded()

            let closing = try #require(strip.cells[closed], "the closed tab left the strip in the close's frame: no shrink")
            #expect(strip.dying.contains(closed), "the closed tab is not closing")
            try #require(!Self.moveKeys(strip).isEmpty, "the close started no strip move")
            let remaining = rig.model.tabs.map(\.id)
            let cells = try remaining.map { id in (id, try #require(strip.cells[id])) }
            let begin = try #require(Self.moveBegin(cells.map(\.1) + [closing]), "the strip move has no begin time")
            let end = (cells.map(\.1) + [closing]).compactMap { cell in
                [MotionPath(cell.layer, "position").end, MotionPath(cell.layer, "bounds.size").end].compactMap { $0 }.max()
            }.max() ?? begin
            try #require(end - begin > 3.0 / 120, "the close did not animate (\(end - begin) s)")

            // The tabs right of the closed one, each sampled per tick from the move's begin to one tick past its end.
            let movers = cells.filter { id, _ in (remaining.firstIndex(of: id) ?? 0) >= index }
            try #require(!movers.isEmpty, "SETUP: no tab right of the closed one")
            var between: [TabID: Int] = [:]
            var closingBetween = 0
            let ticks = Int(((end - begin) * 120).rounded(.up)) + 1
            for k in 0...ticks {
                let time = begin + Double(k) / 120
                for (id, cell) in movers {
                    let from = try #require(start[id]).x, rest = cell.layer.frame.minX, x = Self.shown(cell, at: time).x
                    if abs(rest - from) > 1, min(abs(x - from), abs(x - rest)) > 0.5, (x - from) * (rest - x) > 0 {
                        between[id, default: 0] += 1
                    }
                }
                let width = Self.shown(closing, at: time).width
                let from = try #require(start[closed]).width, rest = closing.layer.bounds.width
                if min(abs(width - from), abs(width - rest)) > 0.5, (width - from) * (rest - width) > 0 { closingBetween += 1 }
                #expect(Self.paneGeometry(rig.pane) == geometry, "tick \(k): the pane's geometry moved")
                #expect(rig.pane.layer?.animationKeys()?.isEmpty ?? true, "tick \(k): the pane animates")
                #expect(rig.pane.contentHost.layer?.animationKeys()?.isEmpty ?? true, "tick \(k): the content host animates")
            }
            for (id, _) in movers {
                #expect((between[id] ?? 0) >= 3, "\(id.rawValue) jumped to its place: \(between[id] ?? 0) ticks between")
            }
            #expect(closingBetween >= 3, "the closed tab did not shrink out: \(closingBetween) ticks between")
        }
    }

    /// Reduce Motion: no slide. The closed tab goes and every tab is at its new place in the close's frame.
    @Test func reduceMotionShowsTheFinalStripInTheClosesFrame() throws {
        try Self.withMotion(reduce: true) {
            let rig = Self.rig(Self.tabs(5), selected: TabID("tab0"))
            let strip = rig.strip
            let geometry = Self.paneGeometry(rig.pane)
            rig.model.tabs.remove(at: 1)
            strip.sync(fromModel: true)
            rig.pane.layoutSubtreeIfNeeded()
            #expect(strip.cells[TabID("tab1")] == nil, "the closed tab stayed to shrink out under Reduce Motion")
            #expect(Self.moveKeys(strip).isEmpty, "the close started strip moves under Reduce Motion: \(Self.moveKeys(strip))")
            let now = CACurrentMediaTime()
            for (id, cell) in strip.cells {
                #expect(abs(Self.shown(cell, at: now).x - cell.layer.frame.minX) < 0.5, "\(id.rawValue) is not at its place")
            }
            #expect(Self.paneGeometry(rig.pane) == geometry, "the pane's geometry moved")
        }
    }

    /// A pane's last tab is never a strip close (cases B, C, D: its pane or its workspace closes as one): it goes in
    /// the close's frame and starts no strip move.
    @Test func aPanesLastTabStartsNoStripMotion() throws {
        try Self.withMotion(reduce: false) {
            let rig = Self.rig(Self.tabs(1), selected: TabID("tab0"))
            rig.model.tabs.removeAll()
            rig.strip.sync(fromModel: true)
            #expect(rig.strip.cells.isEmpty, "the pane's last tab stayed on the strip to shrink out")
            #expect(Self.moveKeys(rig.strip).isEmpty, "the last tab's close started strip moves")
        }
    }

    /// A second close during the slide (two quick Cmd-W) starts from where every tab shows: no tab jumps in the
    /// second close's frame, and the strip slides on to the new places.
    @Test func aSecondCloseDuringTheSlideStartsWhereTheTabsShow() throws {
        try Self.withMotion(reduce: false) {
            try #require(Motion.tabs.animatesMovement, "SETUP: animation speed is off on this host")
            let rig = Self.rig(Self.tabs(6), selected: TabID("tab1"))
            let strip = rig.strip
            rig.model.selectedID = TabID("tab2")
            rig.model.tabs.remove(at: 1)
            strip.sync(fromModel: true)
            try #require(strip.dying.contains(TabID("tab1")), "the first close did not slide")
            // The paths as the first close left them: what the strip would show if nothing else happened.
            let ids = rig.model.tabs.dropFirst(2).map(\.id)
            let before = try ids.map { id -> (TabID, MotionPath, MotionPath) in
                let cell = try #require(strip.cells[id])
                return (id, MotionPath(cell.layer, "position"), MotionPath(cell.layer, "bounds.size"))
            }
            rig.model.selectedID = TabID("tab3")
            rig.model.tabs.removeAll { $0.id == TabID("tab2") }
            strip.sync(fromModel: true)
            let now = CACurrentMediaTime()
            #expect(strip.dying.contains(TabID("tab2")), "the second close did not slide")
            for (id, position, size) in before {
                let cell = try #require(strip.cells[id])
                let was = position.value(at: now).x - cell.layer.anchorPoint.x * size.value(at: now).x
                let shows = Self.shown(cell, at: now).x
                #expect(abs(shows - was) < 0.5, "\(id.rawValue) jumped \(shows - was) pt when the second close began")
                #expect(MotionPath(cell.layer, "position").moves(after: now + 2.0 / 120), "\(id.rawValue) does not slide on")
            }
        }
    }
}
