import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// The strip's clip as layer structure (plans/cmux-next/chrome-parity/p03-rendering.md):
/// the strip's panes sit in a container whose layer masks to its bounds, the docks stack above it, no
/// pane computes or carries a clip of its own on a spring frame, and a zoom moves no host. A page drawing
/// in its own window still leaves out the panes in front of it, read at its clip read
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

    /// True when nothing of `under` shows through `zooming` (felt 1d: the zooming pane has a resting pane's material, no
    /// fill; each pane under it is cut where it shows): `under` has no fill of its own and its cover hole holds all of
    /// `zooming`'s shown rect inside `under`, or the two do not meet.
    static func cut(_ under: PaneHostView, by zooming: PaneHostView, in view: ScreenContentView) -> Bool {
        guard zooming.layer?.backgroundColor == nil else { return false }
        let shown = view.convert(view.shownFrame(zooming), to: under).intersection(under.bounds)
        guard !shown.isNull, shown.width > 0.5, shown.height > 0.5 else { return true }
        guard let mask = under.layer?.mask as? ZoomCoverMaskLayer else { return false }
        return mask.cover.insetBy(dx: -0.5, dy: -0.5).contains(shown)
    }

    /// A view that takes the keys and counts each time it gives them up.
    final class Responder: NSView {
        private(set) var resigns = 0
        override var acceptsFirstResponder: Bool { true }
        override func resignFirstResponder() -> Bool {
            resigns += 1
            return super.resignFirstResponder()
        }
    }

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

    /// A strip pane beside the docked chat zooms and unzooms: its host never leaves the strip container
    /// (a host taken out of its parent drops the window's first responder, and a terminal hears focus out
    /// and in), so the focused view in it keeps the keys and never resigns. While it moves the container
    /// is lifted (the whole screen, above the chat's pane), the zooming host has no fill (a resting pane's material,
    /// felt 1d) and the chat's pane under it is cut where it shows.
    @Test func aZoomBesideADockMovesNoHostAndKeepsTheFocusedPanesKeys() throws {
        let screen = Harness()
        defer { screen.close() }
        screen.show(ChatDockLinkSplitMotionTests.docked)
        for _ in 1...120 { screen.step() }
        let view = try #require(screen.screen), link = try #require(screen.host(Self.anchor))
        let container = view.stripContainer
        #expect(link.superview === container)
        let responder = Responder(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        link.content.addSubview(responder)
        try #require(screen.window.makeFirstResponder(responder), "the test view did not take the keys")

        screen.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf(Self.anchor)), zoomed: true)])
        screen.root.syncWithModel()
        #expect(view.zoomMotion.pane == Self.anchor, "the zoom does not move the link's pane")
        var frames = 0, wrong: [String] = []
        repeat {
            if link.superview !== container { wrong.append("zoom \(frames): the host left the strip container") }
            if view.zoomMotion.pane != nil, link.layer?.backgroundColor != nil { wrong.append("zoom \(frames): the zooming host has a fill") }
            frames += 1
        } while frames < 240 && screen.root.advanceFrame(ChatDockLinkSplitMotionTests.dt)
        #expect(view.zoomMotion.pane == nil, "the zoom did not land in \(frames) frames")

        screen.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: ChatDockLinkSplitMotionTests.docked)])
        screen.root.syncWithModel()
        // The unzoom's frames: the chat's pane is back in its docked column, and the link's pane springs
        // back over it while that column is there (`geometry.dock` is not empty).
        #expect(view.zoomMotion.pane == Self.anchor, "the unzoom does not move the link's pane")
        #expect(!view.geometry.dock.isEmpty, "the unzoomed layout has no docked column")
        let chat = try #require(screen.host(Self.dock))
        frames = 0
        repeat {
            if view.zoomMotion.pane != nil {
                if link.superview !== container {
                    wrong.append("unzoom \(frames): the unzooming pane left the strip container; it must stay there, lifted above the docks")
                }
                if !container.isLifted || container.frame != view.bounds {
                    wrong.append("unzoom \(frames): the strip container is not lifted to the screen: \(container.frame)")
                }
                let order = view.subviews
                if chat.superview !== view || (order.firstIndex(of: container) ?? -1) < (order.firstIndex(of: chat) ?? .max) {
                    wrong.append("unzoom \(frames): the unzooming pane is not above the chat's pane")
                }
                if !Self.cut(chat, by: link, in: view) { wrong.append("unzoom \(frames): the chat's pane is not cut where the unzooming pane shows") }
            }
            frames += 1
        } while frames < 240 && screen.root.advanceFrame(ChatDockLinkSplitMotionTests.dt)
        #expect(view.zoomMotion.pane == nil, "the unzoom did not land in \(frames) frames")
        #expect(wrong.isEmpty, "\(wrong.prefix(6).joined(separator: "; "))")
        #expect(link.superview === container, "the landed pane is not in the strip container")
        #expect(!container.isLifted && abs(container.frame.minX - view.geometry.clipMinX) < 0.5,
                "the landed strip container is not the strip's range: \(container.frame)")
        let order = view.subviews
        #expect((order.firstIndex(of: container) ?? .max) < (order.firstIndex(of: chat) ?? -1), "the chat's pane is not above the strip again")
        #expect(link.layer?.mask == nil && link.layer?.backgroundColor == nil)
        #expect(screen.window.firstResponder === responder, "the focused view lost the keys")
        #expect(responder.resigns == 0, "the focused view resigned \(responder.resigns) times: a terminal sends focus out and in")
    }

    /// A strip beside a docked column (dock, the link's pane, a second strip pane): the link's pane
    /// zooms. The second pane stays under it, in the lifted container, clipped to the strip's range it
    /// had by a mask set once when the zoom starts (not per frame), and the docked pane stays under the
    /// container. On every frame the zooming host is in front of both and both are cut where it shows (no fill, felt 1d), so
    /// neither shows through its padding or header; a page in the covered pane leaves out the zooming
    /// pane (`pageCovers`).
    @Test func aZoomOverAStripBesideADockKeepsTheCoveredPanesClip() throws {
        let other: PaneID = "other"
        let layout = ScreenLayout.columns([
            LayoutColumn(id: ChatDockLinkSplitMotionTests.dockColumn, width: 0.3, root: .leaf(Self.dock),
                         dock: DockColumn(edge: .left, role: .agentChat)),
            LayoutColumn(id: "c1", width: 0.4, root: .leaf(Self.anchor)),
            LayoutColumn(id: "c2", width: 0.4, root: .leaf(other)),
        ])
        let screen = Harness()
        defer { screen.close() }
        screen.show(layout)
        for _ in 1...120 { screen.step() }
        let view = try #require(screen.screen), link = try #require(screen.host(Self.anchor))
        let covered = try #require(screen.host(other)), chat = try #require(screen.host(Self.dock))
        let range = view.stripContainer.frame
        #expect(covered.superview === view.stripContainer && chat.superview === view)

        screen.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf(Self.anchor)), zoomed: true)])
        screen.root.syncWithModel()
        try #require(view.zoomMotion.pane == Self.anchor && view.stripContainer.isLifted, "the zoom did not lift the strip container")
        let computed = view.stripClipsComputed
        var frames = 0, wrong: [String] = [], overlapped = 0
        while view.zoomMotion.pane != nil, frames < 240 {
            if let mask = covered.layer?.mask {
                let shown = mask.frame.offsetBy(dx: covered.frame.minX, dy: covered.frame.minY)
                if !range.insetBy(dx: -0.5, dy: -0.5).contains(shown) {
                    wrong.append("frame \(frames): the covered pane shows \(shown) past the strip \(range)")
                }
            } else if !range.insetBy(dx: -0.5, dy: -0.5).contains(covered.frame) {
                wrong.append("frame \(frames): the covered pane lost its strip clip")
            }
            let stacked = view.stackedSubviews
            if (stacked.firstIndex(of: link) ?? -1) < max(stacked.firstIndex(of: covered) ?? .max, stacked.firstIndex(of: chat) ?? .max) {
                wrong.append("frame \(frames): the zooming pane is not in front")
            }
            if !Self.cut(covered, by: link, in: view) || !Self.cut(chat, by: link, in: view) {
                wrong.append("frame \(frames): a pane under the zooming one is not cut where it shows")
            }
            let shared = link.frame.intersection(covered.frame)
            if !shared.isNull, shared.width > 0.5, shared.height > 0.5 {
                overlapped += 1
                let covers = covered.pageCovers()
                if !covers.contains(covered.convert(view.shownFrame(link), from: view)) {
                    wrong.append("frame \(frames): the covered pane's page does not leave out the zooming pane: \(covers)")
                }
            }
            // One clip per pane under the zooming one on a frame its cut moves (O(covered panes)), none for others.
            if view.stripClipsComputed - computed > 2 * (frames + 1) {
                wrong.append("frame \(frames): \(view.stripClipsComputed - computed) clips computed in \(frames + 1) zoom frames")
            }
            frames += 1
            screen.step()
        }
        #expect(view.zoomMotion.pane == nil, "the zoom did not land in \(frames) frames")
        #expect(overlapped > 3, "the zooming pane never grew over the covered one")
        #expect(wrong.isEmpty, "\(wrong.prefix(6).joined(separator: "; "))")
        #expect(link.superview === view.stripContainer && !view.stripContainer.isLifted)
    }

    /// The covers a page in its own window reads come from the real stacking: in a strip that runs on
    /// under a docked column, the docked pane is in front of the strip pane under it (a dock in the
    /// screen, the strip pane in the container under it), and a strip pane beside the dock has none.
    /// Read again with nothing changed, the answer is the one kept (`coverVersion`).
    @Test func aDockedPaneIsInFrontOfTheStripPaneUnderIt() throws {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2")),
            LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: .docked)),
        ])
        let screen = Harness()
        defer { screen.close() }
        screen.show(layout)
        screen.model.focus("p1")
        screen.root.syncWithModel()
        for _ in 1...240 { screen.step() }
        let view = try #require(screen.screen)
        let p1 = try #require(screen.host("p1")), p2 = try #require(screen.host("p2")), chat = try #require(screen.host("chat"))
        try #require(p2.frame.intersection(chat.frame).width > 1, "p2 does not run on under the dock: \(p2.frame), dock \(chat.frame)")
        #expect(p2.superview === view.stripContainer && chat.superview === view)
        let covers = p2.pageCovers()
        #expect(covers == [p2.convert(view.shownFrame(chat), from: view)], "p2's covers \(covers), the dock \(chat.frame)")
        #expect(p1.pageCovers().isEmpty, "p1 is beside the dock: \(p1.pageCovers())")
        #expect(chat.pageCovers().isEmpty, "nothing is in front of the dock: \(chat.pageCovers())")
        let version = view.coverVersion
        #expect(p2.pageCovers() == covers && view.coverVersion == version)
    }

    /// The child-window fallback: a page that draws in its own window leaves out the parts the panes in
    /// front of its pane cover, asked from its pane (`PageCoverSource`) at the clip read; a page hosted
    /// in the window's layer tree leaves out none.
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
        // Hosted in the window's layer tree, the page is ordered with the views: no cutouts.
        #expect(ChildWindowPageFallback.cutouts(around: page, isHosted: { _ in true }).isEmpty,
                "a layer-hosted page leaves out the pane in front")
    }
}
