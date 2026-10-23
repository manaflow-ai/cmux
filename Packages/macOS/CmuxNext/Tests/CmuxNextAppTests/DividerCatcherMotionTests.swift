import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// Lawrence (2026-10-23): splits lag, more with Chromium pages. While a page window shows, every
/// divider hit area has a click-catching panel above the pages (`DividerMouseCatchers`). Each
/// frame of a split, close, zoom or New Column moved the dividers, so each frame moved every moving
/// divider's panel (one window server move each, a new panel for a new divider) and re-ran divider
/// hover: at 30 panes 64 % of `advanceFrame` (PL-motion-core profile, cmux10s, b553d0648b1). Nobody
/// grabs a divider on a spring: the window's catcher areas, which every panel follows, change once
/// when the layout lands and never during the motion.
@MainActor @Suite(.serialized) struct DividerCatcherMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A shell window whose content is a layout of two side-by-side panes, its overlay layer
    /// adopting the layout's plane, as the app wires them; the test drives the frames.
    struct Layout {
        let window: ShellWindow
        let model: LayoutModel
        let root: LayoutRootView
        let provider = Panes()

        /// Two side-by-side columns, the right one split in two (`columns: true`), else one column split in two.
        static func columns(rightRatio: Double) -> [LayoutColumn] {
            [LayoutColumn(id: "l", width: 0.5, root: .leaf("a")),
             LayoutColumn(id: "r", width: 0.5, root: .split("t", axis: .horizontal, ratio: rightRatio, a: .leaf("b"), b: .leaf("c")))]
        }

        init(columns: Bool = false) {
            _ = NSApplication.shared
            let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns ? Self.columns(rightRatio: 0.5) : [column]))],
                                activeScreenID: "s", focusedPane: "a")
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
            settle()
        }

        @discardableResult
        func settle() -> Int {
            var frames = 0
            while frames < 480, root.advanceFrame(1.0 / 120) { frames += 1 }
            return frames
        }

        var catcherAreas: [CGRect] { window.overlayLayer.catcherAreas.map(\.rect) }
        var dividerAreas: [CGRect] { window.overlayLayer.dividerAreas.map(\.rect) }
    }

    @Test func aSplitMovesNoCatcherAreaUntilItLands() throws {
        let layout = Layout()
        defer { layout.window.close() }
        let before = layout.catcherAreas
        try #require(!before.isEmpty, "the split's divider has a catcher area: \(layout.window.overlayLayer.dividerAreas)")

        // A third pane splits off the right one: the existing divider springs left, a new one grows in.
        let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                                    b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
        layout.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
        layout.root.syncWithModel()

        var springFrames = 0, catcherChangesInMotion = 0, dividerChangesInMotion = 0
        var lastCatchers = layout.catcherAreas, lastDividers = layout.dividerAreas
        while springFrames < 480, layout.root.advanceFrame(1.0 / 120) {
            springFrames += 1
            if layout.catcherAreas != lastCatchers { catcherChangesInMotion += 1 }
            if layout.dividerAreas != lastDividers { dividerChangesInMotion += 1 }
            (lastCatchers, lastDividers) = (layout.catcherAreas, layout.dividerAreas)
        }
        try #require(springFrames > 4 && dividerChangesInMotion > 4, "the split animated: \(springFrames) frames, dividers moved \(dividerChangesInMotion)")
        // The frame the spring landed in returned false: the catchers follow there, once.
        #expect(catcherChangesInMotion <= 1, "catcher areas changed on \(catcherChangesInMotion) of \(springFrames) spring frames")
        #expect(layout.catcherAreas == layout.dividerAreas, "at rest the catchers cover the dividers: \(layout.catcherAreas) vs \(layout.dividerAreas)")
        #expect(layout.catcherAreas.count == before.count + 1, "the new split's divider has its area at rest: \(before) -> \(layout.catcherAreas)")
    }

    /// Review 1 (2026-10-23): a layout parked mid-spring (a workspace switch during a split) never
    /// steps to its landing, so the catchers kept the other layout's divider places after it came back.
    @Test func aLayoutParkedMidSpringGetsItsCatchersWhenItShowsAgain() throws {
        let layout = Layout()
        defer { layout.window.close() }
        let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                                    b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
        layout.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
        layout.root.syncWithModel()
        for _ in 0..<3 { layout.root.advanceFrame(1.0 / 120) }
        try #require(layout.root.isInLayoutMotion, "the split is under way")
        layout.root.isHidden = true
        layout.root.isHidden = false
        layout.settle()
        #expect(!layout.root.isInLayoutMotion)
        #expect(layout.catcherAreas == layout.dividerAreas, "the shown layout's catchers cover its dividers: \(layout.catcherAreas) vs \(layout.dividerAreas)")
    }

    /// Review 1 (finding 3): during a spring the catchers keep their rest places, where the dividers
    /// no longer are; a click there must reach whatever is under it (a page), not a stale catcher.
    /// The held areas whose divider moved are pass-through until the landing.
    @Test func catchersAtRestPlacesLetTheMouseThroughDuringTheSpring() throws {
        let layout = Layout()
        defer { layout.window.close() }
        let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                                    b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
        layout.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
        layout.root.syncWithModel()
        layout.root.advanceFrame(1.0 / 120)
        try #require(layout.root.isInLayoutMotion)
        // The split's divider moves away from its held place; the column's right edge stays.
        let passing = layout.window.overlayLayer.catcherPassThrough
        #expect(passing.contains("split:s"), "the moving divider's held catcher passes the mouse: \(passing)")
        #expect(!passing.contains("column:c"), "the still column edge keeps its catcher: \(passing)")
        layout.settle()
        #expect(layout.window.overlayLayer.catcherPassThrough.isEmpty, "at rest the catchers take the mouse again")
    }

    /// Review 2 (finding 1): a divider that does not move keeps taking the mouse while another part of
    /// the layout springs (a re-grab right after a drag's release spring, a still divider beside a
    /// springing column): only areas whose divider moved away pass the mouse through.
    @Test func anUnmovedDividerKeepsItsCatcherDuringAnotherSpring() throws {
        let layout = Layout(columns: true)
        defer { layout.window.close() }
        let still = try #require(layout.window.overlayLayer.catcherAreas.first { $0.id == "column:l" }, "\(layout.window.overlayLayer.catcherAreas.map(\.id))")
        // The right column's own split moves; the column edge between the columns stays.
        layout.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(Layout.columns(rightRatio: 0.25)))])
        layout.root.syncWithModel()
        layout.root.advanceFrame(1.0 / 120)
        try #require(layout.root.isInLayoutMotion)
        let passing = layout.window.overlayLayer.catcherPassThrough
        #expect(!passing.isEmpty, "the moving divider's catcher passes the mouse")
        #expect(!passing.contains(still.id), "the still divider \(still.id) keeps its catcher: \(passing)")
    }

    /// Review 2 (finding 3): with a page window over the layout the catcher panels are live; none moves
    /// or is made during a split's spring, and the landing moves them once.
    @Test func noCatcherPanelMovesDuringASplitOverAPageWindow() throws {
        let layout = Layout()
        let page = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 1100, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        layout.window.orderFront(nil)
        layout.window.addChildWindow(page, ordered: .above)
        page.orderFront(nil)
        defer {
            layout.window.removeChildWindow(page)
            page.close()
            layout.window.close()
        }
        layout.window.overlayLayer.evaluate()
        try #require(layout.window.overlayLayer.placement == .overlayWindow, "a page window that draws gets the catchers")
        try #require(!layout.window.overlayLayer.catchers.coveredAreaIDs.isEmpty, "the divider has its catcher panel")
        let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                                    b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
        layout.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
        layout.root.syncWithModel()
        let start = layout.window.overlayLayer.catchers.panelUpdates
        var frames = 0
        while frames < 480, layout.root.advanceFrame(1.0 / 120) {
            frames += 1
            if layout.root.isInLayoutMotion {
                #expect(layout.window.overlayLayer.catchers.panelUpdates == start, "frame \(frames): a catcher panel moved during the spring")
            }
        }
        // At rest every divider's catcher covers it.
        let layer = layout.window.overlayLayer
        let covered = layer.catchers.framesInWindow
        let wanted = Dictionary(layer.catcherAreas.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        #expect(Set(covered.keys) == Set(wanted.keys), "catchers \(covered) vs areas \(wanted) (moves \(layer.catchers.panelUpdates - start))")
        for (id, rect) in wanted {
            let frame = covered[id] ?? .null
            #expect(abs(frame.minX - rect.minX) < 1 && abs(frame.width - rect.width) < 1, "\(id): catcher \(frame), area \(rect)")
        }
    }
}

