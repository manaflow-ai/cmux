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

        init(holdsContent: Bool = false, reduceMotion: Bool = false) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(ZoomTransitionTests.tree))],
                                activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = reduceMotion
            root.holdsContentInMotion = { holdsContent }
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
        let others = ["p1", "p2", "p3"].map(PaneID.init).filter { $0 != pane }
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

    /// Lawrence 2026-10-29: terminal panes resize live with the animation, not at its end. With the feature
    /// `paneHoldsContentInMotion` on (the dogfood set), the zooming pane's content still takes its pane's size in every
    /// frame of both ways, not its rest size from the first frame (the wipe) or its start size until the landing (the snap).
    @Test(arguments: ["p1", "p3"])
    func theZoomingPanesContentLaysOutLiveWithHeldContentOn(_ zoomed: String) throws {
        let screen = Screen(holdsContent: true)
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

    /// A page in its own window under the zooming pane cannot stay under it (a child window draws over every view):
    /// it hears the move at the press, as for a render-server move, and its end once the zoom lands or its pane is let
    /// go, once each way. On v2.2.7-opt it showed over the zooming pane at the unzoom.
    @Test func aPageInItsOwnWindowUnderTheZoomHearsItAtThePressAndItsEndAtTheLanding() throws {
        let screen = Screen()
        let page = try #require(screen.provider.pages["p3"])
        screen.zoom("p1")
        screen.step()
        #expect(page.shows == [true], "the covered page was not told the zoom moves: \(page.shows)")
        for _ in 1...60 { screen.step() }
        #expect(page.shows == [true, false], "the zoom told the covered page \(page.shows)")
        screen.unzoom()
        let back = try #require(screen.provider.pages["p3"])
        screen.step()
        #expect(back.shows.first == true, "the returning page was not told the unzoom moves: \(back.shows)")
        for _ in 1...60 { screen.step() }
        #expect(back.shows.last == false && back.shows.filter { $0 }.count == 1, "the unzoom told the page \(back.shows)")
    }

    /// The zooming pane's own page follows its frame on every frame: it is not hidden for its own zoom.
    @Test func theZoomingPanesOwnPageIsNotHidden() throws {
        let screen = Screen()
        let page = try #require(screen.provider.pages["p3"])
        screen.zoom("p3")
        for _ in 1...60 { screen.step() }
        #expect(!page.shows.contains(true), "the zooming page hid for its own zoom: \(page.shows)")
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
        for pane in ["p1", "p2", "p3"].map(PaneID.init) {
            #expect(screen.host(pane)?.layer?.mask == nil, "\(pane) keeps a mask at rest")
        }
    }
}
