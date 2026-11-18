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

    /// Pane content that is no producer itself and names one inside it (`PaneCommitSurfaceHosting`), as a container of
    /// tabs names its shown tab's.
    final class Hosting: Content, PaneCommitSurfaceHosting {
        let inner = Surface()
        var commitSurfaces: [any PaneCommitSurface] { [inner] }
    }

    final class Panes: LayoutPaneContentProvider {
        /// Every pane's content is of the kind that kept one size while its pane moved on a layout spring.
        let holds: Bool
        /// Every pane's content is a ``Surface``; with `hosted`, a ``Hosting`` with one inside.
        let surfaces: Bool, hosted: Bool
        private(set) var contents: [PaneID: Content] = [:]
        /// The panes whose content the layout released, in order.
        private(set) var released: [PaneID] = []
        /// The panes the provider counts as shown: the ones made, less the ones a close took out or the layout
        /// released, and again the ones a close gave back.
        private(set) var shown: Set<PaneID> = []

        init(holds: Bool, surfaces: Bool, hosted: Bool) {
            self.holds = holds
            self.surfaces = surfaces
            self.hosted = hosted
        }

        func makeContentView(for pane: PaneID) -> NSView {
            let view: Content = hosted ? Hosting() : surfaces ? Surface() : Content()
            view.wantsLayer = true
            if let hosting = view as? Hosting {
                hosting.inner.autoresizingMask = [.width, .height]
                hosting.addSubview(hosting.inner)
            }
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

        func surface(_ pane: PaneID) -> Surface? { contents[pane] as? Surface ?? (contents[pane] as? Hosting)?.inner }
    }

    final class Harness {
        let provider: Panes
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        /// `configure`: sets the model up before the view reads it.
        init(_ screens: [LayoutScreen], focused: PaneID, holds: Bool, surfaces: Bool = false, hosted: Bool = false,
             configure: (LayoutModel) -> Void = { _ in }) {
            provider = Panes(holds: holds, surfaces: surfaces, hosted: hosted)
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
    /// then, from the display frame that shows the change on, the one after it. That frame is the first one after the
    /// change; a zoom's is the one at which the dim that comes over the other panes is at its end (`PaneZoomDimTests`).
    /// Every pane's content is at the rect its pane gives it in each of them, and no content takes more than one new size.
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
        // The display frame that shows the change: the first one. A zoom shows after the dim over the other panes has had
        // its fade in frame time (`PaneZoomDimTests.showFrame(of:)`, read before the zoom; with no dim: the first frame).
        let first = change.name == "zoom" ? PaneZoomDimTests.showFrame(of: screen) : 1
        try #require(first <= Self.frames, "the zoom's dim takes \(first) display frames; this test steps \(Self.frames)")

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
        #expect(new.isShown(by: shown[first]), "display frame \(first) after the change, the one that shows it, does not show its layout: \(shown[first].panes)")
        if first > 1 {
            #expect(old.isShown(by: shown[first - 1]), "the zoom showed before its dim was at its end: display frame \(first - 1) shows \(shown[first - 1].panes)")
        }
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
}
