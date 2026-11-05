import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S1B: the key-resize hold paths that Codex's review of #33874 at b75090d0b38 (PR comment
/// 6612204462) named as untested. The hold (`PaneHostView`, RESIZE KEYS K3, FRAME OWNER S1) holds only each pane's content
/// area (`PaneContentAreaView`); these tests pin how it ends on the paths other than a landing: a host taken out of the
/// screen, Reduce Motion turned on mid-spring, a split or a zoom taking the spring over (with the default live resize and
/// with content the provider holds), and content shown during the hold; and how held content converts points and takes
/// clicks while its area's bounds origin keeps it on the held edges.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct FrameOwnerS1HoldPathsTests {
    /// A pane's content: every size it takes, and every frame it had when it heard the motion settled.
    final class Content: NSView, PaneMotionSettling {
        var sizes: [CGSize] = []
        var settled: [CGRect] = []
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }
        func paneMotionDidSettle() { settled.append(frame) }
    }

    final class Panes: LayoutPaneContentProvider {
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        var views: [PaneID: PaneContentView] = [:]
        var contents: [PaneID: Content] = [:]
        /// whether the provider holds every pane's content through a split, close or zoom spring (an agent chat does, S3).
        var holdsContent = false

        func makeContentView(for pane: PaneID) -> NSView {
            let tabs = (0..<2).map { TabItem(id: TabID("\(pane.rawValue)-tab\($0)"), title: "python3 /tmp/sigwinch.py --seed 100\($0)") }
            let view = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: reveal)
            let content = Content()
            view.show(content)
            views[pane] = view
            contents[pane] = content
            return view
        }

        func holdsContentInMotion(for pane: PaneID) -> Bool { holdsContent }
    }

    /// One screen of one column with `node` in a 1200 x 800 window; the test is the clock and runs the landing's
    /// after-commit work when it says.
    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var afterCommit: [@MainActor () -> Void] = []

        init(_ node: SplitNode, holdsContent: Bool = false) {
            _ = NSApplication.shared
            provider.holdsContent = holdsContent
            model = LayoutModel(screens: [Self.screen(node)], activeScreenID: "s", focusedPane: "p2")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            // Weak: a test that ends mid-spring closes its window with motion in flight, and the root's settle asks for
            // after-commit work once this rig is gone.
            root.context.afterCommit = { [weak self] in self?.afterCommit.append($0) }
        }

        static func screen(_ node: SplitNode, zoomed: Bool = false) -> LayoutScreen {
            LayoutScreen(id: "s", name: "s", layout: .columns([LayoutColumn(id: "c0", width: 1, root: node)]), zoomed: zoomed)
        }

        /// Steps up to `limit` frames (each with the window's layout pass), `check` after each; returns the frames that moved.
        @discardableResult
        func frames(_ limit: Int = 240, check: (Int) -> Void = { _ in }) -> Int {
            var count = 0
            while count < limit, root.advanceFrame(1.0 / 120) {
                count += 1
                root.layoutSubtreeIfNeeded()
                check(count)
            }
            return count
        }

        /// The landing's after-commit work, then the layout pass after it.
        func release() {
            let work = afterCommit
            afterCommit.removeAll()
            for item in work { item() }
            root.layoutSubtreeIfNeeded()
        }

        /// Shown panes whose strip is off their pane's content rect, in device pixels.
        func strayStrips(_ label: String) -> [String] {
            provider.views.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { pane in
                guard let host = root.context.hosts[pane], host.window != nil, !host.isHiddenOrHasHiddenAncestor,
                      let view = provider.views[pane], !view.stripView.isHidden else { return nil }
                let area = host.convert(host.contentRect, to: nil), strip = view.stripView.convert(view.stripView.bounds, to: nil)
                guard area.width >= 1, area.height >= 1 else { return nil }
                func px(_ value: CGFloat) -> Int { Int((value * window.backingScaleFactor).rounded()) }
                guard px(strip.minX) != px(area.minX) || px(strip.maxX) != px(area.maxX) || px(strip.maxY) != px(area.maxY) else { return nil }
                return "\(label): \(pane.rawValue) strip \(strip) vs pane \(area)"
            }
        }
    }

    static let pair = SplitNode.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))

    // MARK: A host taken out of the screen

    /// p2's host leaves the screen mid-spring (`viewDidMoveToSuperview`) or after the landing frame, while its release
    /// waits for that frame's commit (the after-commit closure of `isOnLayoutSpring`). Either way its area lets go (once
    /// the release runs, for the second) and its content heard the landing at most once, at the size it holds then.
    @Test(arguments: [false, true])
    func aHostTakenOutOfTheScreenLetsItsAreaGo(afterTheLanding: Bool) throws {
        let rig = Rig(Self.pair)
        defer { rig.window.closeAfterTest() }
        let host = try #require(rig.root.context.hosts["p2"]), view = try #require(rig.provider.views["p2"])
        let content = try #require(rig.provider.contents["p2"])
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        let moved = rig.frames(afterTheLanding ? 240 : 3)
        try #require(moved >= 3 && view.contentHost.isHolding, "p2's area does not hold (\(moved) frames)")
        if afterTheLanding { try #require(!host.isOnLayoutSpring && !rig.afterCommit.isEmpty, "the landing left no release waiting") }
        host.removeFromSuperview()
        rig.release()
        #expect(!view.contentHost.isHolding && view.contentHost.bounds.origin == .zero, "the area of a host taken out of the screen still holds")
        #expect(content.settled.count <= 1, "p2's content heard the landing \(content.settled.count) times")
        #expect(content.frame == view.contentHost.bounds, "p2's content is not at its area's size: \(content.frame) in \(view.contentHost.bounds)")
    }

    // MARK: Reduce Motion mid-spring

    /// Reduce Motion turns on three frames into a key spring: the next frame lands it at once (`LayoutRootView.landMotion`,
    /// `ScreenContentView.settleMotion`); the release lets every area go, each strip is on its pane, and each content took
    /// its final size once and heard the landing once.
    @Test func reduceMotionDuringAKeySpringLandsItAndLetsTheAreasGo() throws {
        let rig = Rig(Self.pair)
        defer { rig.window.closeAfterTest() }
        for content in rig.provider.contents.values { content.sizes.removeAll() }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        try #require(rig.frames(3) == 3 && rig.provider.views.values.allSatisfy { $0.contentHost.isHolding }, "the areas do not hold")
        rig.root.context.reduceMotionOverride = true
        rig.frames()
        rig.release()
        for (pane, view) in rig.provider.views {
            let content = try #require(rig.provider.contents[pane])
            #expect(!view.contentHost.isHolding, "\(pane.rawValue)'s area still holds after Reduce Motion landed the spring")
            #expect(content.frame == view.contentHost.bounds && content.sizes.count == 1,
                    "\(pane.rawValue)'s content: \(content.frame) in \(view.contentHost.bounds), sizes \(content.sizes)")
            #expect(content.settled == [view.contentHost.bounds], "\(pane.rawValue) heard the landing at \(content.settled)")
        }
        #expect(rig.strayStrips("after the landing").isEmpty, "\(rig.strayStrips("after the landing"))")
    }

    // MARK: A split or a zoom taking a key spring over

    enum Takeover: String, CaseIterable, Sendable {
        /// Cmd-D on p2: p3 grows in beside it.
        case split
        /// p2 zooms: it covers p1, which stays where it is under it.
        case zoom
    }

    /// Three frames into a key spring a split or a zoom takes the screen over (`ScreenContentView.update` ->
    /// `PaneHostView.endKeyResizeHold`): the areas let go at once, every strip stays on its pane in every frame of the new
    /// spring, and after its landing nothing holds and each content is at its area's size.
    @Test(arguments: Takeover.allCases)
    func aSplitOrZoomTakingOverAKeySpringLetsTheAreasGo(_ takeover: Takeover) throws {
        let rig = Rig(Self.pair)
        defer { rig.window.closeAfterTest() }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        try #require(rig.frames(3) == 3 && rig.provider.views["p2"]?.contentHost.isHolding == true, "p2's area does not hold")
        switch takeover {
        case .split:
            rig.model.apply(screens: [Rig.screen(.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                                         b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))])
        case .zoom:
            rig.model.apply(screens: [Rig.screen(.leaf("p2"), zoomed: true)])
        }
        rig.root.syncWithModel()
        let held = rig.provider.views.filter { $0.value.contentHost.isHolding }.keys.map(\.rawValue).sorted()
        #expect(held.isEmpty, "the \(takeover.rawValue) did not end the key hold of \(held)")
        var strays: [String] = []
        let frames = rig.frames { strays += rig.strayStrips("frame \($0)") }
        #expect(frames > 3, "the \(takeover.rawValue) did not spring (\(frames) frames)")
        rig.release()
        strays += rig.strayStrips("after the landing")
        #expect(strays.isEmpty, "\(strays.count) strip frames off their pane: \(strays.prefix(4))")
        for (pane, view) in rig.provider.views where !view.isHiddenOrHasHiddenAncestor {
            let content = try #require(rig.provider.contents[pane])
            #expect(!view.contentHost.isHolding && content.frame == view.contentHost.bounds,
                    "\(pane.rawValue): area holding \(view.contentHost.isHolding), content \(content.frame) in \(view.contentHost.bounds)")
        }
    }

    /// With content the provider holds (an agent chat), each spring lays p2's content out once, at that spring's rest size
    /// on its first frame (Leo 2026-11-05: "the main pane waits for the right pane to shift before it shifts. Like, why
    /// are you waiting?"). Ctrl-Shift-L on p2 lays it out at the key spring's rest; the split taking that spring over lays
    /// it out once more, at the split's rest, as its spring starts; no later frame of that spring and not its landing
    /// resizes it.
    @Test func aSplitTakingOverWithHoldContentLaysTheContentOutOncePerSpringAtItsStart() throws {
        let rig = Rig(Self.pair, holdsContent: true)
        defer { rig.window.closeAfterTest() }
        let content = try #require(rig.provider.contents["p2"]), view = try #require(rig.provider.views["p2"])
        content.sizes.removeAll()
        let start = content.frame.size
        #expect(PaneResize.press("p2", .right, model: rig.model, view: rig.root))
        try #require(rig.frames(3) == 3 && view.contentHost.isHolding, "p2's area does not hold")
        rig.model.apply(screens: [Rig.screen(.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                                     b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))])
        rig.root.syncWithModel()
        let atTakeover = content.sizes
        let frames = rig.frames()
        try #require(frames > 3, "the split did not spring (\(frames) frames)")
        rig.release()
        #expect(atTakeover.count == 1 && atTakeover.first != start,
                "p2's content did not take the key spring's rest once, at its start: \(atTakeover) (start \(start))")
        #expect(content.frame == view.contentHost.bounds && content.sizes.count == 2 && content.sizes.first == atTakeover.first,
                "p2's content did not take the split's rest once more and then hold it to the landing: \(content.sizes) (\(content.frame) in \(view.contentHost.bounds))")
    }

    // MARK: Content shown during the hold

    /// Two frames into a key spring p2 shows another tab's content: it joins the held area at the held size
    /// (`PaneContentAreaView.contentBounds`), rides the held edges with the rest, never shows under the strip, and takes
    /// the area's size once, at the release.
    @Test func contentShownDuringAKeySpringJoinsTheHoldAndTakesItsSizeOnceAtTheRelease() throws {
        let rig = Rig(Self.pair)
        defer { rig.window.closeAfterTest() }
        let view = try #require(rig.provider.views["p2"])
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        try #require(rig.frames(2) == 2 && view.contentHost.isHolding, "p2's area does not hold")
        let joiner = Content()
        view.show(joiner)
        rig.root.layoutSubtreeIfNeeded()
        var off: [String] = []
        func check(_ label: String) {
            if joiner.frame != view.contentHost.contentBounds { off.append("\(label): joiner \(joiner.frame), held rect \(view.contentHost.contentBounds)") }
            let shown = joiner.convert(joiner.visibleRect, to: nil), strip = view.stripView.convert(view.stripView.bounds, to: nil)
            if !shown.isEmpty, shown.maxY > strip.minY + 0.25 { off.append("\(label): the joiner shows under the strip (\(shown.maxY) > \(strip.minY))") }
        }
        check("at the switch")
        let moved = rig.frames { check("frame \($0)") }
        try #require(moved > 1, "the spring landed at the switch (\(moved) frames after it)")
        rig.release()
        #expect(off.isEmpty, "\(off.count) frames off: \(off.prefix(4))")
        #expect(joiner.frame == view.contentHost.bounds && joiner.sizes.count == 2,
                "the joiner did not take the held size, then its rest size once: \(joiner.sizes) (\(joiner.frame) in \(view.contentHost.bounds))")
    }

    // MARK: Points and clicks in held content

    /// A flipped view inside the held content of an area that holds on each pair of edges and is now smaller than when
    /// the hold began: a click in the area reaches the subview drawn there, and points convert between the window and
    /// the subview at the place the subview shows.
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func heldContentTakesClicksAndConvertsPointsWhereItShows(trailing: Bool, bottom: Bool) throws {
        final class Flipped: NSView { nonisolated override var isFlipped: Bool { true } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root
        let area = PaneContentAreaView(frame: NSRect(x: 100, y: 50, width: 400, height: 300))
        root.addSubview(area)
        let content = NSView(frame: area.bounds)
        content.autoresizingMask = [.width, .height]
        area.addSubview(content)
        // A flipped marker 40 x 30 at the content's top-left corner (content coordinates: y up), kept at the top.
        let marker = Flipped(frame: NSRect(x: 0, y: content.bounds.height - 30, width: 40, height: 30))
        marker.autoresizingMask = [.minYMargin]
        content.addSubview(marker)
        area.hold = PaneMotionHold(trailing: trailing, bottom: bottom)
        area.setFrameSize(NSSize(width: 300, height: 220))
        try #require(area.isHolding && content.frame.size == NSSize(width: 400, height: 300), "the held content did not keep its size")
        // Where the held content shows: its pinned edges on the area's.
        let shown = content.convert(content.bounds, to: nil), areaInWindow = area.convert(area.bounds, to: nil)
        #expect(trailing ? shown.maxX == areaInWindow.maxX : shown.minX == areaInWindow.minX, "held x edge: \(shown) in \(areaInWindow)")
        #expect(bottom ? shown.minY == areaInWindow.minY : shown.maxY == areaInWindow.maxY, "held y edge: \(shown) in \(areaInWindow)")
        // Round trips between the window and the flipped marker.
        let point = CGPoint(x: 7, y: 5)
        #expect(marker.convert(marker.convert(point, to: nil), from: nil) == point)
        // A click on the marker where it shows reaches it, when it shows in the area.
        let markerInWindow = marker.convert(marker.bounds, to: nil)
        let visible = markerInWindow.intersection(areaInWindow)
        if !visible.isEmpty {
            let click = CGPoint(x: visible.midX, y: visible.midY)
            let inSuperview = root.superview?.convert(click, from: nil) ?? click // hitTest takes its superview's coordinates
            #expect(root.hitTest(inSuperview) === marker, "a click at \(click) did not reach the marker at \(markerInWindow)")
        }
        // The release fills the area at once: the bounds origin back at zero, the content at the area's size.
        area.hold = nil
        #expect(!area.isHolding && content.frame == area.bounds && area.bounds.origin == .zero, "the release did not fill the area")
        #expect(marker.frame.maxY == content.bounds.height, "the marker did not stay at the content's top after the release")
    }
}
