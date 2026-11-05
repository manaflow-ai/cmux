import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// SMOOTH-STRIP (cmux-ad m18, RESIZE MAIN BUDGET STATUS 13566 item 3 and 13922): in a key resize or a divider drag the
/// strip of each moving pane ran the layout engine and wrote every tab cell's frame in each frame
/// (`TabStripView.layout` -> `relayout` -> `applyFrames`), 0.4-0.9 ms per p99 frame in keys-held STRESS, though a
/// width change moves no slot edge while the tabs are at their widest or narrowest (the strip scrolls).
///
/// The rule: in every frame of a key resize each strip writes the frames of exactly the cells whose frames change; a
/// frame that moves no slot edge runs no layout engine and lays out no cell's parts. At rest, the strip's slots and its
/// cells' frames are a full layout's.
///
/// The panes show the app's pane content (`PaneContentView`: a tab strip over its content); the frames step at a fixed
/// 120 Hz dt (`TabStripFollowsPaneTickTests`' clock).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct TabStripResizeFrameWorkTests {
    /// Each pane shows the app's pane content with `tabCount` tabs.
    final class Panes: LayoutPaneContentProvider {
        let tabCount: Int
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        var views: [PaneID: PaneContentView] = [:]

        init(tabCount: Int) { self.tabCount = tabCount }

        func makeContentView(for pane: PaneID) -> NSView {
            let tabs = (0..<tabCount).map { TabItem(id: TabID("\(pane.rawValue)-tab\($0)"), title: "python3 /tmp/sigwinch.py --seed 100\($0)") }
            let view = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: reveal)
            view.show(NSView())
            views[pane] = view
            return view
        }
    }

    /// p1 | p2 in a 1200 x 800 window; the test is the clock.
    final class Rig {
        let provider: Panes
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var afterCommit: [@MainActor () -> Void] = []

        init(tabCount: Int) {
            _ = NSApplication.shared
            provider = Panes(tabCount: tabCount)
            let node = SplitNode.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([LayoutColumn(id: "c0", width: 1, root: node)]))],
                                activeScreenID: "s", focusedPane: "p2")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.context.afterCommit = { [unowned self] in self.afterCommit.append($0) }
        }

        var strips: [(PaneID, TabStripView)] {
            provider.views.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { pane in provider.views[pane].map { (pane, $0.stripView) } }
        }
    }

    /// One strip before a frame: what it showed and what it had done.
    struct Before {
        let frames: [TabID: CGRect]
        let edges: [CGFloat]
        let cellFrames: Int
        let cellLayouts: Int
        let engineRuns: Int

        init(_ strip: TabStripView) {
            frames = strip.cells.mapValues(\.frame)
            edges = Self.edges(strip)
            cellFrames = strip.cells.values.reduce(0) { $0 + $1.workCounts.frames }
            cellLayouts = strip.cells.values.reduce(0) { $0 + $1.workCounts.layouts }
            engineRuns = strip.rowPasses.layouts
        }

        /// Every slot's leading and trailing edge, in content coordinates.
        static func edges(_ strip: TabStripView) -> [CGFloat] { strip.result.slots.flatMap { [$0.x, $0.maxX] } }

        /// What `strip` did in the frame since this, against the rule; empty when it kept it.
        func breaches(_ strip: TabStripView, label: String) -> [String] {
            let changed = strip.cells.filter { frames[$0.key] != $0.value.frame }.count
            let written = strip.cells.values.reduce(0) { $0 + $1.workCounts.frames } - cellFrames
            let laidOut = strip.cells.values.reduce(0) { $0 + $1.workCounts.layouts } - cellLayouts
            let runs = strip.rowPasses.layouts - engineRuns
            var found: [String] = []
            if written != changed { found.append("\(label): wrote \(written) cell frames, \(changed) changed") }
            if Self.edges(strip) == edges {
                if runs > 0 { found.append("\(label): no slot edge moved, the layout engine ran \(runs) times") }
                if laidOut > 0 { found.append("\(label): no slot edge moved, \(laidOut) cells laid out their parts") }
            }
            return found
        }
    }

    /// The strip at rest is a full layout's: its result is the engine's for its items at its width, and each cell sits
    /// at its slot.
    static func offFullLayout(_ strip: TabStripView, label: String) -> [String] {
        let full = TabLayoutEngine.layout(items: strip.layoutItems(), availableWidth: strip.viewportWidth, style: strip.model.style,
                                          metrics: strip.metrics, closingModeWidth: strip.closingModeWidth,
                                          fullWidthTab: strip.model.showsSelectedFullWidth ? strip.model.selectedID : nil)
        var found: [String] = []
        if strip.result != full { found.append("\(label): slots \(strip.result.slots.map { ($0.x, $0.width) }) vs a full layout's \(full.slots.map { ($0.x, $0.width) })") }
        for slot in full.slots {
            guard let cell = strip.cells[slot.id] else { continue }
            let frame = strip.cellFrame(TabPlace(x: slot.x, width: slot.width), isPinned: cell.item.isPinned)
            if cell.frame != frame { found.append("\(label): \(slot.id.rawValue) at \(cell.frame), its slot's frame is \(frame)") }
        }
        return found
    }

    /// Steps `press` on p2 to its landing; each frame (the tick and the window's layout pass) is checked against the
    /// rule. Returns the frames, the breaches, and the frames in which some strip moved a slot edge.
    static func run(_ rig: Rig, presses: [LayoutDirection]) throws -> (frames: Int, breaches: [String], edgeFrames: Int) {
        var frames = 0, breaches: [String] = [], edgeFrames = 0
        func frame(_ label: String, _ step: () -> Void) {
            let before = rig.strips.map { ($0.0, $0.1, Before($0.1)) }
            step()
            rig.root.layoutSubtreeIfNeeded()
            frames += 1
            var moved = false
            for (pane, strip, snapshot) in before {
                breaches += snapshot.breaches(strip, label: "\(label) \(pane.rawValue)")
                moved = moved || Before.edges(strip) != snapshot.edges
            }
            if moved { edgeFrames += 1 }
        }
        for (index, direction) in presses.enumerated() {
            try #require(PaneResize.press("p2", direction, model: rig.model, view: rig.root), "press \(index + 1) moved nothing")
            var moving = true, steps = 0
            while moving, steps < 240 {
                frame("press \(index + 1) frame \(steps + 1)") { moving = rig.root.advanceFrame(1.0 / 120) }
                steps += 1
            }
        }
        frame("landing release") {
            let release = rig.afterCommit
            rig.afterCommit.removeAll()
            for work in release { work() }
        }
        return (frames, breaches, edgeFrames)
    }

    /// 12 tabs in each pane: they sit at their narrowest and the strip scrolls, at every width the press passes, so no
    /// frame moves a slot edge (STRESS panes: 6 tabs in a quarter of the window). Red at feat edc897c37ff: each frame
    /// ran the engine and wrote every cell's frame in both strips.
    @Test(arguments: [LayoutDirection.left, .right])
    func aKeyResizeThatMovesNoSlotEdgeWritesNoCell(_ direction: LayoutDirection) throws {
        let rig = Rig(tabCount: 12)
        defer { rig.window.closeAfterTest() }
        try #require(rig.strips.count == 2)
        for (pane, strip) in rig.strips {
            try #require(strip.cells.count == 12, "\(pane.rawValue) shows \(strip.cells.count) tabs")
            try #require(strip.result.isOverflowing, "\(pane.rawValue)'s tabs do not scroll at \(strip.viewportWidth) pt")
        }
        let widths = rig.strips.map(\.1.viewportWidth)
        let (frames, breaches, edgeFrames) = try Self.run(rig, presses: [direction])
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        try #require(rig.strips.map(\.1.viewportWidth) != widths, "the press changed no strip's width")
        #expect(edgeFrames == 0, "\(edgeFrames) frames moved a slot edge")
        #expect(breaches.isEmpty, "\(breaches.count) breaches in \(frames) frames: \(breaches.prefix(6))")
        for (pane, strip) in rig.strips { #expect(Self.offFullLayout(strip, label: pane.rawValue).isEmpty, "\(Self.offFullLayout(strip, label: pane.rawValue))") }
    }

    /// 5 tabs in each pane share its row (narrower than their widest, wider than their narrowest): the press moves slot
    /// edges in most frames. Each frame writes only the cells whose frames change; at rest the strip is a full layout's.
    /// Red at feat edc897c37ff: every cell was written in each frame, moved or not.
    @Test(arguments: [LayoutDirection.left, .right])
    func aKeyResizeThatMovesSlotEdgesWritesOnlyTheCellsThatMove(_ direction: LayoutDirection) throws {
        let rig = Rig(tabCount: 5)
        defer { rig.window.closeAfterTest() }
        for (pane, strip) in rig.strips {
            try #require(strip.cells.count == 5)
            try #require(!strip.result.isOverflowing && strip.result.standardWidth < strip.metrics.maxTabWidth - 0.5,
                         "\(pane.rawValue)'s tabs do not share the row: \(strip.result.standardWidth) pt at \(strip.viewportWidth)")
        }
        let (frames, breaches, edgeFrames) = try Self.run(rig, presses: [direction, direction])
        try #require(edgeFrames > 3, "only \(edgeFrames) of \(frames) frames moved a slot edge")
        #expect(breaches.isEmpty, "\(breaches.count) breaches in \(frames) frames: \(breaches.prefix(6))")
        for (pane, strip) in rig.strips { #expect(Self.offFullLayout(strip, label: pane.rawValue).isEmpty, "\(Self.offFullLayout(strip, label: pane.rawValue))") }
    }
}
