import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// The strip's clip as layer structure (p03-rendering-023, plans/cmux-next/chrome-parity/p03-rendering.md):
/// beside docked columns the strip's panes sit in a container whose layer masks to its bounds, the docks
/// stack above it, and no pane computes or carries a clip of its own on a spring frame. A page drawing in
/// its own window still leaves out the panes in front of it, read at its clip read
/// (`ChildWindowPageFallback`), never computed per frame.
@MainActor
struct StripClipLayerStructureTests {
    typealias Harness = ChatDockLinkSplitMotionTests.Screen
    static let anchor = ChatDockLinkSplitMotionTests.anchor
    static let dock = ChatDockLinkSplitMotionTests.dock

    static func narrower() -> ScreenLayout {
        .columns([
            LayoutColumn(id: ChatDockLinkSplitMotionTests.dockColumn, width: 0.3, root: .leaf(dock),
                         dock: DockColumn(edge: .left, role: .agentChat)),
            LayoutColumn(id: "c1", width: 1, root: .leaf(anchor)),
        ])
    }

    /// Hosts of `view` that carry a layer mask.
    static func masked(_ view: ScreenContentView) -> Int { view.displayedHosts.filter { $0.layer?.mask != nil }.count }

    /// The link's pane slides in beside the docked chat, then the chat's column narrows: every frame of
    /// both springs moves or resizes the strip pane, and none computes a strip clip or puts a mask on a
    /// host (the base recomputed the sliding pane's mask on every frame).
    @Test func springFramesBesideADockComputeNoClipAndAddNoMask() throws {
        let screen = Harness()
        defer { screen.close() }
        screen.model.handOffContent(of: Self.anchor)
        screen.show(ChatDockLinkSplitMotionTests.docked)
        let view = try #require(screen.screen), link = try #require(screen.host(Self.anchor))
        // The change's own pass (the structural reconcile) places everything once; the springs follow.
        let computed = view.stripClipsComputed
        var frames: [CGRect] = [link.frame], masks = 0
        for _ in 1...120 {
            screen.step()
            frames.append(link.frame)
            masks += Self.masked(view)
        }
        #expect(Set(frames.map(\.minX)).count > 3, "the link's pane did not slide in: \(frames.map(\.minX))")
        #expect(view.stripClipsComputed == computed, "the slide computed \(view.stripClipsComputed - computed) strip clips")

        screen.show(Self.narrower())
        let resized = view.stripClipsComputed, before = link.frame
        var widths: Set<CGFloat> = []
        for _ in 1...120 {
            screen.step()
            widths.insert(link.frame.width)
            masks += Self.masked(view)
        }
        #expect(widths.count > 3, "the strip pane did not spring to its new width: \(before) -> \(link.frame)")
        #expect(view.stripClipsComputed == resized, "the resize spring computed \(view.stripClipsComputed - resized) strip clips")
        #expect(masks == 0, "spring frames put \(masks) masks on hosts")
    }

    /// The layer order, back to front: the strip container (holding the strip's pane) under the docked
    /// chat's pane, which covers the strip by order, not by a mask.
    @Test func theDockStacksAboveTheStripInLayerOrder() throws {
        let screen = Harness()
        defer { screen.close() }
        screen.show(ChatDockLinkSplitMotionTests.docked)
        for _ in 1...120 { screen.step() }
        let view = try #require(screen.screen)
        let container = view.stripContainer
        let layers = try #require(view.layer?.sublayers)
        let order: [String] = layers.compactMap { layer in
            if layer === container.layer {
                let strip = container.subviews.compactMap { ($0 as? PaneHostView)?.pane.rawValue }
                return "strip[\(strip.joined(separator: ","))]"
            }
            return view.subviews.first { $0.layer === layer }.flatMap { ($0 as? PaneHostView)?.pane.rawValue }
        }
        #expect(order == ["strip[\(Self.anchor.rawValue)]", Self.dock.rawValue], "layer order \(order)")
        #expect(view.stackedSubviews.compactMap { ($0 as? PaneHostView)?.pane } == [Self.anchor, Self.dock])
    }

    /// A zoom takes the zooming strip pane out of the strip container (it is above the docks until it
    /// lands) and its landing puts it back: the unzoom's spring shows it whole over the chat, and at
    /// rest it is clipped with the strip again.
    @Test func aZoomingStripPaneLeavesTheContainerUntilItLands() throws {
        let screen = Harness()
        defer { screen.close() }
        screen.show(ChatDockLinkSplitMotionTests.docked)
        for _ in 1...120 { screen.step() }
        let view = try #require(screen.screen), link = try #require(screen.host(Self.anchor))
        #expect(link.superview === view.stripContainer)

        screen.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf(Self.anchor)), zoomed: true)])
        screen.root.syncWithModel()
        #expect(link.superview === view, "the zooming pane stayed in the strip container")
        for _ in 1...120 { screen.step() }

        screen.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: ChatDockLinkSplitMotionTests.docked)])
        screen.root.syncWithModel()
        #expect(view.zoomMotion.pane == Self.anchor, "the unzoom does not move the link's pane")
        #expect(link.superview === view, "the unzooming pane is in the strip container, under the docks")
        var frames = 0
        while frames < 240, screen.root.advanceFrame(ChatDockLinkSplitMotionTests.dt) { frames += 1 }
        #expect(view.zoomMotion.pane == nil, "the unzoom did not land in \(frames) frames")
        #expect(link.superview === view.stripContainer, "the landed pane is not back in the strip container")
        #expect(link.layer?.mask == nil)
    }

    /// The child-window fallback: a page that draws in its own window leaves out the parts the panes in
    /// front of its pane cover, asked from its pane (`PageCoverSource`) at the clip read.
    @Test func aChildWindowPageLeavesOutWhatThePaneInFrontCovers() throws {
        final class Source: NSView, PageCoverSource {
            var covers: [CGRect] = []
            func pageCovers() -> [CGRect] { covers }
        }
        let source = Source(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let page = CEFHostView(frame: CGRect(x: 20, y: 10, width: 300, height: 200))
        source.addSubview(page)
        #expect(ChildWindowPageFallback.cutouts(around: page).isEmpty)
        let corner = CGRect(x: 0, y: 0, width: 80, height: 60)
        source.covers = [corner]
        let cutouts = ChildWindowPageFallback.cutouts(around: page)
        #expect(cutouts == [page.convert(corner, from: source)], "cutouts \(cutouts)")
        let path = try #require(CEFClipShape.Inputs(around: page).path, "the page's clip leaves nothing out")
        let inside = page.convert(CGPoint(x: 40, y: 30), from: source), outside = page.convert(CGPoint(x: 200, y: 150), from: source)
        #expect(!path.contains(inside), "the page shows under the pane in front")
        #expect(path.contains(outside), "the page is cut away where nothing covers it")
    }
}
