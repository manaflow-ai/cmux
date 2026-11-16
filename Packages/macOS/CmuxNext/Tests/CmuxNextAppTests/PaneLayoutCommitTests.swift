import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// A layout change whose end is known when it starts (a split, a close, a zoom, an unzoom) is one commit: every frame
/// the screen presents shows the panes and dividers of ONE layout, each at that layout's rest rect, and each pane's
/// content at the rect its pane gives it. No frame shows a pane between two layouts, a pane whose content has another
/// size than its pane gives it, a pane the layout no longer has beside one it just got, or a content that changed size
/// more than once.
///
/// The oracle is the layout engine: `ScreenGeometry.compute` of the layout before the change and of the layout after
/// it, computed here from the model, never read back from the screen's own frames. The test is the clock: it steps
/// `LayoutRootView.advanceFrame` itself, one display frame at a time.
@MainActor
@Suite(.closesItsWindows) struct PaneLayoutCommitTests {
    /// Pane content that records each size it takes (a size with no area is no size: a pane not placed yet has none).
    class Content: NSView {
        private(set) var sizes: [CGSize] = []

        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size, newSize.width > 0, newSize.height > 0 { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }
    }

    /// Pane content whose pixels come from another thread or process, as a layout change reads it: it records the size
    /// changes it hears and reports ready when the test says.
    final class Surface: Content, PaneCommitSurface {
        private(set) var asks: [CGSize] = []
        private var ready: (@MainActor () -> Void)?

        func commitWillResize(by change: CGSize, ready: @escaping @MainActor () -> Void) {
            asks.append(change)
            self.ready = ready
        }

        /// Its picture at the size it last heard shows from now on.
        func report() {
            let ready = self.ready
            self.ready = nil
            ready?()
        }
    }

    final class Panes: LayoutPaneContentProvider {
        /// Every pane's content is of the kind that kept one size while its pane moved on a layout spring.
        let holds: Bool
        /// Every pane's content is a ``Surface``.
        let surfaces: Bool
        private(set) var contents: [PaneID: Content] = [:]
        /// The panes whose content the layout released, in order.
        private(set) var released: [PaneID] = []
        /// The panes the provider counts as shown: the ones made, less the ones a close took out or the layout
        /// released, and again the ones a close gave back.
        private(set) var shown: Set<PaneID> = []

        init(holds: Bool, surfaces: Bool) {
            self.holds = holds
            self.surfaces = surfaces
        }

        func makeContentView(for pane: PaneID) -> NSView {
            let view = surfaces ? Surface() : Content()
            view.wantsLayer = true
            contents[pane] = view
            shown.insert(pane)
            return view
        }

        func holdsContentInMotion(for pane: PaneID) -> Bool { holds }

        func releaseContentView(_ view: NSView, for pane: PaneID) {
            released.append(pane)
            shown.remove(pane)
        }

        func retainContentView(_ view: NSView, for pane: PaneID, retired: Bool) {
            if retired { shown.remove(pane) } else { shown.insert(pane) }
        }

        func surface(_ pane: PaneID) -> Surface? { contents[pane] as? Surface }
    }

    final class Harness {
        let provider: Panes
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        /// `configure`: sets the model up before the view reads it.
        init(_ screens: [LayoutScreen], focused: PaneID, holds: Bool, surfaces: Bool = false, configure: (LayoutModel) -> Void = { _ in }) {
            provider = Panes(holds: holds, surfaces: surfaces)
            model = LayoutModel(screens: screens, activeScreenID: "s", focusedPane: focused)
            configure(model)
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            // The test steps the frames: no display link runs beside it.
            root.driver.isManual = true
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }

        var screen: ScreenContentView? { root.screenViews.values.first }
    }

    /// What one presented frame shows.
    struct Frame {
        /// Each shown pane host's frame in its screen.
        var panes: [PaneID: CGRect] = [:]
        /// Each shown divider's frame in its screen.
        var dividers: [CGRect] = []
        /// The panes whose content is not at the rect its pane gives it (content frame, pane's content rect).
        var misfits: [PaneID: (content: CGRect, area: CGRect)] = [:]
    }

    static func shown(_ screen: ScreenContentView) -> Frame {
        var frame = Frame()
        for view in screen.subviews where !view.isHidden && view.alphaValue > 0 && view.frame.width > 0 && view.frame.height > 0 {
            if let host = view as? PaneHostView {
                frame.panes[host.pane] = host.frame
                // A pane that shows no content of its own (its content view is hidden) fits nothing.
                let content = host.convert(host.content.frame, from: host.content.superview)
                if host.content.isHidden || !near(content, host.contentRect) { frame.misfits[host.pane] = (content, host.contentRect) }
            } else if view is DividerHandleView {
                frame.dividers.append(view.frame)
            }
        }
        return frame
    }

    /// One layout as the layout engine rests it in `screen`: the oracle.
    struct Rest {
        var panes: [PaneID: CGRect]
        var dividers: [CGRect]

        /// `camerasAtEnd`: the strip's camera and each row column's rest at their ends (the layout scrolled as far as it
        /// goes, which is nowhere when it fits its screen); else at their starts.
        @MainActor
        init(_ screens: [LayoutScreen], in screen: ScreenContentView, style: LayoutStyle, camerasAtEnd: Bool = false) {
            let base = ScreenGeometry.compute(screens[0].layout, viewport: screen.bounds.size, style: style, scale: screen.scale)
            let geometry = camerasAtEnd ? base.shiftingRows(base.rowStacks.mapValues(\.maxOffset)) : base
            let strip = geometry.viewShift(offset: camerasAtEnd ? base.maxOffset : 0)
            panes = geometry.panes.reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value.offsetBy(dx: geometry.scrolls(pane: entry.key) ? strip : 0, dy: 0)
            }
            dividers = geometry.dividers.map { $0.hitFrame.offsetBy(dx: geometry.fixedSplits.contains($0.id) ? 0 : strip, dy: 0) }
                + geometry.columnEdges.map { $0.hitFrame.offsetBy(dx: $0.dockEdge == nil ? strip : 0, dy: 0) }
        }

        /// Whether `frame` shows exactly this layout: its panes and no other, each at its rest rect, and its dividers.
        func isShown(by frame: Frame) -> Bool {
            guard Set(frame.panes.keys) == Set(panes.keys), frame.dividers.count == dividers.count else { return false }
            guard panes.allSatisfy({ pane, rect in frame.panes[pane].map { PaneLayoutCommitTests.near($0, rect) } ?? false }) else { return false }
            return dividers.allSatisfy { rect in frame.dividers.contains { PaneLayoutCommitTests.near($0, rect) } }
        }
    }

    /// Whether two frames show the same panes and dividers at the same places.
    static func same(_ a: Frame, _ b: Frame) -> Bool {
        guard Set(a.panes.keys) == Set(b.panes.keys), a.dividers.count == b.dividers.count else { return false }
        guard a.panes.allSatisfy({ pane, rect in b.panes[pane].map { near($0, rect) } ?? false }) else { return false }
        return a.dividers.allSatisfy { rect in b.dividers.contains { near($0, rect) } }
    }

    /// Equal on the device-pixel grid: the screen puts each edge on the nearest pixel.
    nonisolated static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 0.51 && abs(a.maxX - b.maxX) <= 0.51 && abs(a.minY - b.minY) <= 0.51 && abs(a.maxY - b.maxY) <= 0.51
    }

    // MARK: Layouts

    static let left = PaneID("left"), right = PaneID("right"), added = PaneID("added")

    static func screen(_ node: SplitNode, zoomed: Bool = false) -> [LayoutScreen] {
        [LayoutScreen(id: "s", name: "s", layout: .splits(node), zoomed: zoomed)]
    }

    /// Two panes side by side.
    static var pair: [LayoutScreen] {
        screen(.split(SplitID("pair"), axis: .horizontal, ratio: 0.5, a: .leaf(left), b: .leaf(right)))
    }

    /// The pair with its left pane split along `axis` (`.horizontal`: to the right, `.vertical`: down).
    static func pairSplit(_ axis: SplitAxis) -> [LayoutScreen] {
        let halves = SplitNode.split(SplitID("new"), axis: axis, ratio: 0.5, a: .leaf(left), b: .leaf(added))
        return screen(.split(SplitID("pair"), axis: .horizontal, ratio: 0.5, a: halves, b: .leaf(right)))
    }

    /// The pair zoomed on its left pane.
    static var pairZoomed: [LayoutScreen] { screen(.leaf(left), zoomed: true) }

    struct Change: CustomTestStringConvertible, Sendable {
        let name: String
        /// The pane contents kept one size on a layout spring (an agent chat's rule) or took each frame's size.
        let holds: Bool
        var testDescription: String { "\(name), content \(holds ? "held" : "live")" }
    }

    nonisolated static let changes: [Change] = ["split right", "split down", "close", "zoom", "unzoom", "split in a column"].flatMap { name in
        [Change(name: name, holds: false), Change(name: name, holds: true)]
    }

    static func layouts(of change: Change) -> (before: [LayoutScreen], after: [LayoutScreen]) {
        switch change.name {
        case "split right": (pair, pairSplit(.horizontal))
        case "split down": (pair, pairSplit(.vertical))
        case "close": (pairSplit(.horizontal), pair)
        case "zoom": (pair, pairZoomed)
        case "unzoom": (pairZoomed, pair)
        default: (PaneMotionBench.grid(2, 1), PaneMotionBench.split(2, 1, axis: .horizontal))
        }
    }

    /// 300 ms of display frames at 120 Hz: longer than any motion may be.
    static let frames = 36

    // MARK: Tests

    /// The frame of the change's own turn and each display frame after it show one layout: the one before the change,
    /// then, from the first display frame on, the one after it. Every pane's content is at the rect its pane gives it in
    /// each of them, and no content takes more than one new size.
    @Test(arguments: changes)
    func aLayoutChangeShowsInOneFrame(_ change: Change) throws {
        let (before, after) = Self.layouts(of: change)
        // An unzoom starts from a zoom the screen showed: the panes that zoom covered come back, they are not made.
        let harness = Harness(change.name == "unzoom" ? Self.pair : before,
                              focused: change.name == "split in a column" ? PaneID("p0-0") : Self.left, holds: change.holds)
        defer { harness.window.closeAfterTest() }
        if change.name == "unzoom" {
            harness.model.apply(screens: before)
            harness.root.syncWithModel()
        }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let old = Rest(harness.model.screens, in: screen, style: style)
        #expect(old.isShown(by: Self.shown(screen)), "the screen does not rest at the layout before the change: \(Self.shown(screen).panes)")
        let sizesBefore = harness.provider.contents.mapValues(\.sizes.count)

        harness.model.apply(screens: after)
        let new = Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        var shown = [Self.shown(screen)]
        for _ in 0..<Self.frames {
            _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
            shown.append(Self.shown(screen))
        }

        #expect(screen.scroll.value == 0 && screen.scroll.target == 0, "the strip's camera moved; the oracle has no camera")
        var reached = false
        for (index, frame) in shown.enumerated() {
            if new.isShown(by: frame) {
                reached = true
            } else {
                #expect(!reached, "frame \(index) leaves the layout after the change: panes \(frame.panes), dividers \(frame.dividers)")
                #expect(old.isShown(by: frame),
                        "frame \(index) shows neither layout: panes \(frame.panes), dividers \(frame.dividers); before \(old.panes), after \(new.panes)")
            }
            #expect(frame.misfits.isEmpty, "frame \(index): a pane's content is not at the rect its pane gives it: \(frame.misfits)")
        }
        #expect(new.isShown(by: shown[1]), "the first display frame after the change does not show its layout: \(shown[1].panes)")
        #expect(reached, "the layout after the change never showed")
        for (pane, content) in harness.provider.contents {
            let took = content.sizes.count - (sizesBefore[pane] ?? 0)
            #expect(took <= 1, "\(pane)'s content took \(took) sizes in one layout change: \(content.sizes.suffix(took))")
        }
    }

    /// Display frames until nothing moves (at most 2 s of them): the screen is at rest.
    static func rest(_ harness: Harness) {
        var moving = true, count = 0
        while moving, count < 240 {
            moving = harness.root.advanceFrame(PaneMotionBench.frameBudget)
            count += 1
        }
    }

    /// A second change in the turn of the first (two keys in one frame), and one a display frame later: each frame still
    /// shows one of the layouts the changes went through, in their order, and ends at the last.
    @Test(arguments: [0, 1])
    func twoLayoutChangesShowOnlyWholeLayouts(framesBetween: Int) throws {
        let harness = Harness(Self.pair, focused: Self.left, holds: false)
        defer { harness.window.closeAfterTest() }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        var states = [Rest(harness.model.screens, in: screen, style: style)]

        var shown: [Frame] = []
        harness.model.apply(screens: Self.pairSplit(.horizontal))
        states.append(Rest(harness.model.screens, in: screen, style: style))
        harness.root.syncWithModel()
        shown.append(Self.shown(screen))
        for _ in 0..<framesBetween {
            _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
            shown.append(Self.shown(screen))
        }
        harness.model.apply(screens: Self.pair)
        states.append(Rest(harness.model.screens, in: screen, style: style))
        harness.root.syncWithModel()
        shown.append(Self.shown(screen))
        for _ in 0..<Self.frames {
            _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
            shown.append(Self.shown(screen))
        }

        var state = 0
        for (index, frame) in shown.enumerated() {
            let next = (state..<states.count).first { states[$0].isShown(by: frame) }
            #expect(next != nil, "frame \(index) shows no whole layout: panes \(frame.panes), dividers \(frame.dividers)")
            if let next { state = next }
            #expect(frame.misfits.isEmpty, "frame \(index): a pane's content is not at the rect its pane gives it: \(frame.misfits)")
        }
        #expect(states[2].isShown(by: shown[shown.count - 1]), "the last frame is not the last layout")
    }

    // MARK: Surfaces

    /// A producer on another thread or in another process hears its new size in the change's turn, and the change waits
    /// for it: no frame shows the new layout before the producer reported, and the first frame tick after its report
    /// shows it. A pane the change does not resize hears nothing.
    @Test func aChangeWaitsForTheSurfacesItResizesAndShowsWhenTheyReport() throws {
        let harness = Harness(Self.pair, focused: Self.left, holds: false, surfaces: true)
        defer { harness.window.closeAfterTest() }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let old = Rest(harness.model.screens, in: screen, style: style)
        let left = try #require(harness.provider.surface(Self.left)), right = try #require(harness.provider.surface(Self.right))

        harness.model.apply(screens: Self.pairSplit(.horizontal))
        let new = Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        #expect(left.asks.count == 1 && right.asks.isEmpty, "only the resized pane's surface hears a size: \(left.asks), \(right.asks)")
        let change = try #require(left.asks.first), was = try #require(old.panes[Self.left]), will = try #require(new.panes[Self.left])
        #expect(abs(change.width - (will.width - was.width)) <= 1.02 && abs(change.height - (will.height - was.height)) <= 1.02,
                "the surface hears how much its pane's size changes: \(change), from \(was) to \(will)")
        #expect(old.isShown(by: Self.shown(screen)), "the change's own turn shows the new layout")

        #expect(harness.root.advanceFrame(PaneMotionBench.frameBudget), "a change that waits asks for no more frames")
        #expect(old.isShown(by: Self.shown(screen)), "a frame tick showed the new layout before its surface reported")
        left.report()
        #expect(old.isShown(by: Self.shown(screen)), "the report showed the new layout outside a frame tick")
        #expect(!harness.root.advanceFrame(PaneMotionBench.frameBudget), "frames run on after the change showed")
        #expect(new.isShown(by: Self.shown(screen)), "the first frame tick after the report does not show the new layout")
        #expect(screen.lateSurfaceCommits == 0 && harness.root.context.hosts[Self.left]?.showsLateGround == false,
                "a surface that reported in time counts as late")
    }

    /// A producer that does not report: the change shows at its bound, counted in frame ticks (the bound, then the tick
    /// that shows it), never later. That pane shows its own ground, counted as late; every other pane is whole. No frame
    /// tick runs after it. The ground goes when the producer reports, with no frame tick.
    @Test func aSurfaceThatNeverReportsShowsItsPanesGroundAtTheBound() throws {
        let harness = Harness(Self.pair, focused: Self.left, holds: false, surfaces: true)
        defer { harness.window.closeAfterTest() }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let old = Rest(harness.model.screens, in: screen, style: style)
        let left = try #require(harness.provider.surface(Self.left))

        harness.model.apply(screens: Self.pairSplit(.horizontal))
        let new = Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        for tick in 1...ScreenContentView.commitBound {
            #expect(harness.root.advanceFrame(PaneMotionBench.frameBudget), "tick \(tick): the change stopped asking for frames inside its bound")
            #expect(old.isShown(by: Self.shown(screen)), "tick \(tick): the new layout showed inside the bound with a surface not ready")
        }
        #expect(!harness.root.advanceFrame(PaneMotionBench.frameBudget), "a frame tick is asked for after the change showed at its bound")
        #expect(new.isShown(by: Self.shown(screen)), "the change did not show at the tick after its bound")
        let hosts = harness.root.context.hosts
        #expect(hosts[Self.left]?.showsLateGround == true, "the late pane does not show its ground")
        #expect(hosts[Self.right]?.showsLateGround == false && hosts[Self.added]?.showsLateGround == false, "a pane that is not late shows ground")
        #expect(screen.lateSurfaceCommits == 1, "the late pane is not counted once: \(screen.lateSurfaceCommits)")
        for _ in 0..<Self.frames {
            #expect(!harness.root.advanceFrame(PaneMotionBench.frameBudget), "a late surface keeps the frames running")
        }
        #expect(hosts[Self.left]?.showsLateGround == true, "the ground went before the surface reported")
        left.report()
        #expect(hosts[Self.left]?.showsLateGround == false, "the ground stays after the surface reported")
    }

    /// A pane a close takes out is shown until the close shows, hidden in the frame that shows it, and torn down only
    /// after that frame's commit: the frame that shows the close carries no teardown. The provider's shown panes lose
    /// it in the close's own turn (a key, a focus or a lookup there never finds a closed pane); only its teardown waits.
    @Test func aClosedPaneIsTornDownAfterTheFrameThatShowsTheClose() throws {
        let harness = Harness(Self.pairSplit(.horizontal), focused: Self.left, holds: false)
        defer { harness.window.closeAfterTest() }
        var afterCommit: [@MainActor () -> Void] = []
        harness.root.context.afterCommit = { afterCommit.append($0) }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let closed = try #require(harness.root.context.hosts[Self.added])

        harness.model.apply(screens: Self.pair)
        harness.root.syncWithModel()
        #expect(!closed.isHidden && closed.superview === screen, "the closed pane left the screen before the close showed")
        #expect(harness.provider.shown == [Self.left, Self.right], "the close's own turn left the closed pane among the provider's shown panes: \(harness.provider.shown)")
        _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
        #expect(closed.isHidden, "the closed pane still shows in the frame that shows the close")
        #expect(harness.provider.released.isEmpty, "the closed pane was torn down in the frame that shows the close")
        let work = afterCommit
        afterCommit = []
        for item in work { item() }
        #expect(harness.provider.released == [Self.added], "the closed pane was not torn down after that frame's commit: \(harness.provider.released)")
        #expect(closed.superview == nil && closed.chrome.superview == nil, "the closed pane's host or its ring is still in the view tree")
    }

    /// A close taken back before it showed (the daemon refused it): the pane never left the screen, it has the host and
    /// the content it had, and nothing is released.
    @Test func aCloseTakenBackBeforeItShowedKeepsThePaneAsItWas() throws {
        let harness = Harness(Self.pairSplit(.horizontal), focused: Self.left, holds: false)
        defer { harness.window.closeAfterTest() }
        var afterCommit: [@MainActor () -> Void] = []
        harness.root.context.afterCommit = { afterCommit.append($0) }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let whole = Rest(harness.model.screens, in: screen, style: style)
        let closed = try #require(harness.root.context.hosts[Self.added])

        harness.model.apply(screens: Self.pair)
        harness.root.syncWithModel()
        #expect(closed.hitTest(NSPoint(x: closed.frame.midX, y: closed.frame.midY)) == nil, "a pane that is leaving takes clicks")
        harness.model.apply(screens: Self.pairSplit(.horizontal))
        harness.root.syncWithModel()
        #expect(harness.root.context.hosts[Self.added] === closed, "the pane that came back has another host")
        #expect(harness.provider.shown == [Self.left, Self.added, Self.right], "the pane that came back is not among the provider's shown panes: \(harness.provider.shown)")
        #expect(whole.isShown(by: Self.shown(screen)), "the screen changed in the turns of a close and of its return")
        for _ in 0..<Self.frames {
            _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
            #expect(whole.isShown(by: Self.shown(screen)), "a frame shows another layout after the close was taken back")
        }
        let work = afterCommit
        afterCommit = []
        for item in work { item() }
        #expect(harness.provider.released.isEmpty, "the pane that came back was released: \(harness.provider.released)")
        #expect(!closed.isHidden && !closed.chrome.isHidden && closed.hitTest(NSPoint(x: closed.frame.midX, y: closed.frame.midY)) != nil,
                "the pane that came back does not show, or takes no clicks")
    }

    /// A close that changes no pane's size (a strip column between two columns that keep their widths) waits for no
    /// frame tick: it shows in its own turn, and the closed pane is torn down after that turn's commit.
    @Test func aCloseThatResizesNoPaneShowsInItsOwnTurn() throws {
        func strip(_ panes: [Int]) -> [LayoutScreen] {
            [LayoutScreen(id: "s", name: "s", layout: .columns(panes.map { PaneMotionBench.column($0, rows: 1, width: 0.25) }))]
        }
        let harness = Harness(strip([0, 1, 2]), focused: PaneID("p0-0"), holds: false)
        defer { harness.window.closeAfterTest() }
        // The columns that stay keep their widths (no setting of the Mac the test runs on resizes them).
        harness.model.newColumnWidthModeOverride = .matchCurrent
        var afterCommit: [@MainActor () -> Void] = []
        harness.root.context.afterCommit = { afterCommit.append($0) }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let closed = try #require(harness.root.context.hosts[PaneID("p1-0")])

        harness.model.apply(screens: strip([0, 2]))
        let new = Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        #expect(new.isShown(by: Self.shown(screen)), "a close that resizes nothing did not show in its own turn: \(Self.shown(screen).panes)")
        #expect(closed.isHidden && harness.provider.released.isEmpty, "the turn that shows the close did not hide the closed pane, or tore it down")
        #expect(harness.provider.shown == [PaneID("p0-0"), PaneID("p2-0")], "the close's own turn left the closed pane among the provider's shown panes: \(harness.provider.shown)")
        #expect(!harness.root.advanceFrame(PaneMotionBench.frameBudget), "a close that showed asks for frames")
        let work = afterCommit
        afterCommit = []
        for item in work { item() }
        #expect(harness.provider.released == [PaneID("p1-0")] && closed.superview == nil, "the closed pane was not torn down after that turn's commit")
    }

    // MARK: A close that moves a camera

    /// One full-width column of rows (`heights` in permille of the column), as the daemon sends it: the rows, and the
    /// chain of vertical splits that holds every pane. Rows of more than 1000 in all overflow, and the column scrolls.
    static func rows(_ heights: [Int]) -> [LayoutScreen] {
        let rows = heights.enumerated().map { index, height in
            LayoutRow(id: RowID("r\(index + 1)"), height: height, root: .leaf(PaneID("p\(index + 1)")))
        }
        func chain(_ rest: ArraySlice<LayoutRow>) -> SplitNode {
            guard rest.count > 1, let first = rest.first else { return rest.first?.root ?? .leaf("p1") }
            return .split(SplitID("v\(first.id.rawValue)"), axis: .vertical, ratio: 1 / Double(rest.count), a: first.root, b: chain(rest.dropFirst()))
        }
        return [LayoutScreen(id: "s", name: "s", layout: .columns([LayoutColumn(id: "c1", width: 1, root: chain(rows[...]), rows: rows)]))]
    }

    /// A strip of the columns `numbers` (column `cN` holds pane `pN`), each half the screen wide: more than two scroll.
    static func strip(_ numbers: [Int]) -> [LayoutScreen] {
        [LayoutScreen(id: "s", name: "s", layout: .columns(numbers.map { LayoutColumn(id: ColumnID("c\($0)"), width: 0.5, root: .leaf(PaneID("p\($0)"))) }))]
    }

    struct CameraClose: CustomTestStringConvertible, Sendable {
        let name: String
        var testDescription: String { name }
    }

    nonisolated static let cameraCloses = [
        CameraClose(name: "the last row, and the rest fit their column"), CameraClose(name: "the last row, and the rows still overflow"),
        CameraClose(name: "the last column of a scrolled strip"), CameraClose(name: "a middle column of a strip scrolled to its end"),
    ]

    /// The layout before the close with the pane that has the focus in it (the pane at its end, so its camera rests at
    /// its end), and the layout after the close with the pane the close's topology focuses.
    static func layouts(of close: CameraClose) -> (before: [LayoutScreen], focused: PaneID, after: [LayoutScreen], focus: PaneID) {
        switch close.name {
        case "the last row, and the rest fit their column": (rows([500, 500, 500]), "p3", rows([500, 500]), "p2")
        case "the last row, and the rows still overflow": (rows([400, 400, 400, 400]), "p4", rows([400, 400, 400]), "p3")
        case "the last column of a scrolled strip": (strip([1, 2, 3]), "p3", strip([1, 2]), "p2")
        default: (strip([1, 2, 3, 4]), "p4", strip([1, 2, 4]), "p4")
        }
    }

    /// A close that leaves a scrolled camera with less to show (the last row of a column whose rows overflow, the last
    /// column of a scrolled strip, a column before the last one): the camera's new place is part of the close. Each
    /// frame shows what the screen showed before the close, or the layout after it with its camera at rest, with
    /// nothing between: no frame shows the panes that stay on their way to their places, beside the ground of the pane
    /// that left.
    @Test(arguments: cameraCloses)
    func aCloseThatMovesACameraShowsInOneFrame(_ close: CameraClose) throws {
        let change = Self.layouts(of: close)
        let harness = Harness(change.before, focused: change.focused, holds: false) { $0.rowsEnabledOverride = true }
        defer { harness.window.closeAfterTest() }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let camera = max(screen.rowScrolls["c1"]?.state.spring.value ?? 0, screen.scroll.value)
        try #require(camera > 100, "set-up: the camera is not scrolled to the pane that closes (\(camera))")
        let before = Self.shown(screen)

        // The app's order for a close: the daemon's tree, then the focus its topology lands.
        harness.model.apply(screens: change.after)
        // At rest the camera shows the end of what the layout still has: all of it, when it fits.
        let after = Rest(harness.model.screens, in: screen, style: harness.root.context.style, camerasAtEnd: true)
        harness.root.syncWithModel()
        harness.model.focus(change.focus, notify: false)
        harness.root.syncWithModel()
        var shown = [Self.shown(screen)]
        for _ in 0..<Self.frames {
            _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
            shown.append(Self.shown(screen))
        }

        var reached = false
        for (index, frame) in shown.enumerated() {
            if after.isShown(by: frame) {
                reached = true
            } else {
                #expect(!reached, "frame \(index) leaves the layout after the close: \(frame.panes)")
                #expect(Self.same(frame, before), "frame \(index) shows neither what showed before the close nor the layout after it: \(frame.panes); after \(after.panes)")
            }
        }
        #expect(after.isShown(by: shown[1]), "the first display frame after the close does not show its layout at rest: \(shown[1].panes)")
    }
}
