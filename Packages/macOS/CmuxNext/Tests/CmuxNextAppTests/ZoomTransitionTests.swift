import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// Felt 1d (Lawrence 2026-10-29, v2.2.7-opt): "animations for cmd shift enter need to be better", "make sure cmd
/// shift enter animation is perfect (all the tabs are perfectly visible)". His clip: an opaque dark layer wiped in
/// over the zoomed pane while its content sat at its end place, the browser pane vanished at the press and showed
/// over the zoom at the unzoom, and the unzoom ended in a second step about 600 ms later.
///
/// The rule (handoff/motion-cascade.md): a zoom is one geometric transition of the real pane content, with a resting
/// pane's material, of at most about 150 ms; nothing under the zooming pane shows through it, the panes it covers stay
/// on screen until it covers them, and a page in its own window (which cannot ride a layer transition) hides for it.
/// Frames step at a fixed 120 Hz dt, so every assertion is about frame N.
@MainActor
struct ZoomTransitionTests {
    /// A pane's content that hears render moves, as a Chromium page in its own window does (`CEFHostView`).
    final class PageLike: NSView, PaneRenderMoveObserving {
        var shows: [Bool] = []
        func paneRenderMoveDidChange(_ showsRenderMove: Bool) { shows.append(showsRenderMove) }
    }

    final class Panes: LayoutPaneContentProvider {
        var pages: [PaneID: PageLike] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let page = PageLike()
            pages[pane] = page
            return page
        }
    }

    static let dt = 1.0 / 120

    /// p1 | p2 / p3: Home left, Home right-top, a page right-bottom, as in the clip.
    static let tree: SplitNode = .split("v", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                        b: .split("r", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(reduceMotion: Bool = false) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(ZoomTransitionTests.tree))],
                                activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = reduceMotion
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        var screen: ScreenContentView? { root.screenViews["s"] }

        func zoom(_ pane: PaneID) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf(pane)), zoomed: true)])
            root.syncWithModel()
        }

        func unzoom() {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(ZoomTransitionTests.tree))])
            root.syncWithModel()
        }

        func host(_ pane: PaneID) -> PaneHostView? { root.context.hosts[pane] }

        /// `host`'s frame in the screen's coordinates.
        func frame(_ pane: PaneID) -> CGRect? {
            guard let host = host(pane), let screen, host.superview != nil else { return nil }
            return screen.convert(host.frame, from: host.superview)
        }

        /// Whether `pane` draws at `point` (screen coordinates): inside its host and not cut away by its mask.
        func draws(_ pane: PaneID, at point: CGPoint) -> Bool {
            guard let host = host(pane), let screen, host.superview != nil, !host.isHidden, host.alphaValue > 0.01 else { return false }
            let local = host.convert(point, from: screen)
            guard host.bounds.contains(local) else { return false }
            guard let mask = host.layer?.mask else { return true }
            if let shape = mask as? CAShapeLayer, let path = shape.path {
                // The mask's bounds are the host's coordinates (its frame is the clip's rect).
                return mask.frame.contains(local) && path.contains(local, using: shape.fillRule == .evenOdd ? .evenOdd : .winding)
            }
            return mask.frame.contains(local)
        }

        @discardableResult
        func step() -> Bool { root.advanceFrame(ZoomTransitionTests.dt) }
    }

    /// Frames of 1/120 s a transition of at most 150 ms takes, and one more for its landing frame.
    static let budgetFrames = Int((0.150 / dt).rounded(.up)) + 1

    @Test(arguments: ["p1", "p2", "p3"])
    func theZoomingPaneHasARestingPanesMaterialInEveryFrame(_ zoomed: String) {
        let screen = Screen()
        let pane = PaneID(zoomed)
        let atRest = screen.host(pane)?.layer?.backgroundColor?.alpha ?? 0
        screen.zoom(pane)
        for frame in 1...40 {
            screen.step()
            let fill = screen.host(pane)?.layer?.backgroundColor?.alpha ?? 0
            #expect(fill == atRest, "zoom frame \(frame): the zooming pane has a fill of alpha \(fill) a resting pane does not have")
        }
        screen.unzoom()
        for frame in 1...40 {
            screen.step()
            let fill = screen.host(pane)?.layer?.backgroundColor?.alpha ?? 0
            #expect(fill == atRest, "unzoom frame \(frame): the unzooming pane has a fill of alpha \(fill)")
        }
    }

    @Test(arguments: ["p1", "p2", "p3"])
    func nothingUnderTheZoomingPaneShowsThroughIt(_ zoomed: String) throws {
        let screen = Screen()
        let pane = PaneID(zoomed)
        let all: [PaneID] = ["p1", "p2", "p3"]
        let others = all.filter { $0 != pane }
        func check(_ phase: String, _ frame: Int) {
            guard let cover = screen.frame(pane) else { return }
            for other in others {
                guard let under = screen.frame(other) else { continue }
                let shared = cover.intersection(under)
                guard !shared.isNull, shared.width > 4, shared.height > 4 else { continue }
                let point = CGPoint(x: shared.midX, y: shared.midY)
                #expect(!screen.draws(other, at: point), "\(phase) frame \(frame): \(other) draws under the zooming pane at \(point)")
            }
        }
        screen.zoom(pane)
        for frame in 1...12 {
            screen.step()
            check("zoom", frame)
        }
        for _ in 1...60 { screen.step() }
        screen.unzoom()
        for frame in 1...12 {
            screen.step()
            check("unzoom", frame)
        }
    }

    @Test(arguments: ["p1", "p2", "p3"])
    func eachWayIsOneTransitionOfAtMost150Ms(_ zoomed: String) throws {
        let screen = Screen()
        let pane = PaneID(zoomed)
        let half = try #require(screen.frame(pane))
        screen.zoom(pane)
        let full = try #require(screen.screen?.geometry.panes[pane])
        var landed: Int?
        for frame in 1...90 {
            screen.step()
            if landed == nil, screen.screen?.zoomMotion.pane == nil, screen.frame(pane) == full { landed = frame }
        }
        #expect((landed ?? .max) <= Self.budgetFrames, "the zoom landed at frame \(landed.map(String.init) ?? "never"), past \(Self.budgetFrames)")
        screen.unzoom()
        landed = nil
        for frame in 1...90 {
            screen.step()
            if landed == nil, screen.screen?.zoomMotion.pane == nil, screen.frame(pane) == half { landed = frame }
        }
        #expect((landed ?? .max) <= Self.budgetFrames, "the unzoom landed at frame \(landed.map(String.init) ?? "never"), past \(Self.budgetFrames)")
    }

    /// Lawrence 2026-10-29: no wipe and no snap. The pane host never holds its content (the feature
    /// `paneHoldsContentInMotion` and its host-level hold are gone, principled audit R3): the content takes the pane's
    /// content area in every frame of both ways, and each landing leaves no hold in the subtree.
    @Test(arguments: ["p1", "p3"])
    func theZoomingPanesHostNeverHoldsItsContent(_ zoomed: String) throws {
        let screen = Screen()
        let pane = PaneID(zoomed)
        let host = try #require(screen.host(pane))
        func check(_ phase: String) {
            var sizes = Set<String>()
            for frame in 1...24 {
                screen.step()
                let content = host.content.frame.size, clip = host.contentRect.size
                sizes.insert("\(content)")
                #expect(content == clip, "\(phase) frame \(frame): content \(content) in a pane content area of \(clip)")
            }
            #expect(sizes.count >= 5, "\(phase): the content took \(sizes.count) sizes")
        }
        screen.zoom(pane)
        check("zoom")
        for _ in 1...60 { screen.step() }
        screen.unzoom()
        check("unzoom")
        for _ in 1...60 { screen.step() }
        for id in ["p1", "p2", "p3"] {
            let violations = screen.host(PaneID(id))?.motionHoldViolations ?? []
            #expect(violations.isEmpty, "\(id): \(violations)")
        }
    }

    /// The panes a zoom covers stay on screen (their content shown, a page included) until the zooming pane covers
    /// them: on v2.2.7-opt the browser pane vanished at the press.
    @Test func theCoveredPanesStayVisibleUntilTheZoomLands() throws {
        let screen = Screen()
        screen.zoom("p1")
        for frame in 1...6 {
            screen.step()
            let visible = try #require(screen.screen?.visiblePanes())
            #expect(visible.isSuperset(of: ["p2", "p3"]), "frame \(frame): visible \(visible.sorted { $0.rawValue < $1.rawValue })")
        }
    }

    /// "All the tabs are perfectly visible": no page is hidden for a zoom, under the zooming pane or in it; a page in
    /// its own window is cut where the zooming pane shows instead (its cutouts, ``coversOfPage``), in every frame.
    @Test(arguments: ["p1", "p3"])
    func noPageHidesForAZoomAndAPageUnderItIsCutWhereItShows(_ zoomed: String) throws {
        let screen = Screen()
        let pane = PaneID(zoomed)
        let pages = screen.provider.pages
        screen.zoom(pane)
        for frame in 1...8 {
            screen.step()
            if pane != "p3", let host = screen.host("p3"), host.superview != nil, let cover = screen.frame(pane),
               let under = screen.frame("p3"), cover.intersection(under).width > 4, cover.intersection(under).height > 4 {
                let cuts = host.pageCovers().map { host.convert($0, to: screen.screen) }
                let shared = cover.intersection(under)
                #expect(cuts.contains { $0.insetBy(dx: -1, dy: -1).contains(shared) },
                        "frame \(frame): the page under the zoom is not cut where the zooming pane shows \(shared): \(cuts)")
            }
        }
        for _ in 1...60 { screen.step() }
        screen.unzoom()
        for _ in 1...60 { screen.step() }
        for (id, page) in pages.merging(screen.provider.pages, uniquingKeysWith: { _, new in new }) {
            #expect(!page.shows.contains(true), "\(id)'s page was hidden for the zoom: \(page.shows)")
        }
    }

    /// Motion off: the zoom and the unzoom apply in one frame, with no cover left on any pane.
    @Test func withMotionOffEachWayAppliesInOneFrame() throws {
        let screen = Screen(reduceMotion: true)
        screen.zoom("p2")
        screen.step()
        #expect(screen.frame("p2") == screen.screen?.geometry.panes["p2"])
        #expect(screen.screen?.zoomMotion.pane == nil)
        screen.unzoom()
        screen.step()
        #expect(screen.screen?.zoomMotion.pane == nil)
        let all: [PaneID] = ["p1", "p2", "p3"]
        for pane in all {
            #expect(screen.host(pane)?.layer?.mask == nil, "\(pane) keeps a mask at rest")
        }
    }
}
