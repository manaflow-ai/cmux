#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// ZOOM VARIANTS 9 (fork only, never merged): the zoom OUT key turn was 3-4 ms longer than the zoom IN one (ZOOM VARIANTS 8
/// profile, C3 K6, n=10 per direction: `LayoutViewContext.host(for:)` in `reconcile` +0.8 ms of `-[NSView
/// _setHidden:setNeedsDisplay:]`, `updateVisibility` +1.0 ms), and the out first moved frame came at refresh 3 in 12-15 of
/// 20 presses. The unzoom took back each covered pane's host by flipping `isHidden` (host, ring, content): AppKit walks
/// the subtree for its hidden ancestor, posts KVO, and rebuilds the window's cursor rects and drag regions in that turn.
/// The rule: a pane whose content stops on parking is covered by paint only. The zoom leaves its host in the tree,
/// unhidden, at opacity 0, parked (its terminal stops as a hidden one does), taking no click; the unzoom's key turn changes
/// paint and parking only: no `isHidden` flip and no hide or unhide callback on any covered pane's views.
/// The test is the clock (120 Hz).
@MainActor
@Suite(.closesItsWindows)
struct FilmZoomCoverByPaintTests {
    /// Content that stops on parking, as a terminal surface does (``ParkingObserver``), and counts AppKit's hide hooks.
    final class Probe: NSView, ParkingObserver {
        var hides = 0, unhides = 0, parkingChanges = 0
        override func viewDidHide() { super.viewDidHide(); hides += 1 }
        override func viewDidUnhide() { super.viewDidUnhide(); unhides += 1 }
        func parkingDidChange() { parkingChanges += 1 }
    }

    final class Panes: LayoutPaneContentProvider {
        var probes: [PaneID: Probe] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let probe = Probe()
            probes[pane] = probe
            return probe
        }
        func coversByPaint(_ pane: PaneID) -> Bool { true }
    }

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init() {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(ZoomKeepsCoveredPanesTests.four))],
                                activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            land()
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        func show(_ tree: SplitNode, zoomed: Bool) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree), zoomed: zoomed)])
            root.syncWithModel()
        }

        func land() {
            var frames = 0
            while root.advanceFrame(1.0 / 120), frames < 600 { frames += 1 }
        }
    }

    /// Counts `isHidden` changes (KVO "hidden") on views.
    @MainActor final class HiddenFlips { var names: [String] = [] }

    @Test(arguments: ["zoom_variant Z4 K6", "zoom_variant Z4 K12"])
    func theUnzoomKeyTurnFlipsNoCoveredPanesHidden(_ variant: String) throws {
        let film = DesignSettings.shared.filmZoom
        defer { DesignSettings.shared.filmZoom = film }
        _ = FilmZoomVariant.select(variant)
        let screen = Screen()
        defer { screen.window.closeAfterTest() }
        let covered: [PaneID] = ["p2", "p3", "p4"]
        let hosts = try covered.map { try #require(screen.root.context.hosts[$0]) }
        let probes = try covered.map { try #require(screen.provider.probes[$0]) }

        // Zoom in, the film to its end: the covered panes are retired until the unzoom.
        screen.show(.leaf("p1"), zoomed: true)
        _ = screen.root.advanceFrame(1.0 / 120)
        screen.screen.stopFilmFade(retiring: true)
        screen.screen.filmMotionEnded(screen.screen.frameInput.filmZoomGeneration)
        screen.land()
        for (pane, host) in zip(covered, hosts) {
            try #require(screen.root.context.hosts[pane] == nil, "\(pane.rawValue) is not retired by the zoom")
            #expect(host.superview === screen.screen, "\(pane.rawValue) left the screen: the zoom keeps covered panes")
            #expect(!host.isHidden && host.layer?.opacity == 0, "\(pane.rawValue) is not covered by paint: hidden \(host.isHidden), opacity \(host.layer?.opacity ?? -1)")
            #expect(!host.chrome.isHidden && host.chrome.layer?.opacity == 0, "\(pane.rawValue)'s ring is not covered by paint")
            let center = NSPoint(x: host.frame.midX, y: host.frame.midY)
            #expect(host.hitTest(center) == nil, "\(pane.rawValue)'s covered host takes the click")
            #expect(host.accessibilityChildren()?.isEmpty ?? true, "\(pane.rawValue)'s covered host lists its content to accessibility")
        }
        for (pane, probe) in zip(covered, probes) {
            #expect(probe.isParkedOrHasParkedAncestor, "\(pane.rawValue)'s content is not parked: a covered terminal keeps drawing")
            #expect(probe.hides == 0, "\(pane.rawValue)'s content got \(probe.hides) viewDidHide: the zoom hid it")
        }

        // The unzoom's key turn.
        let flips = HiddenFlips()
        let views = zip(covered, hosts).flatMap { pane, host in
            [("\(pane.rawValue).host", host as NSView), ("\(pane.rawValue).ring", host.chrome), ("\(pane.rawValue).content", host.content)]
        }
        let watches = views.map { name, view in
            view.observe(\.isHidden, options: [.old, .new]) { _, change in
                MainActor.assumeIsolated { // main-proof: the key turn runs on the main thread
                    if change.oldValue != change.newValue { flips.names.append(name) }
                }
            }
        }
        defer { watches.forEach { $0.invalidate() } }
        let unhidesBefore = probes.map(\.unhides)
        screen.show(ZoomKeepsCoveredPanesTests.four, zoomed: false)
        #expect(flips.names.isEmpty, "the unzoom's key turn flipped isHidden: \(flips.names)")
        #expect(probes.map(\.unhides) == unhidesBefore, "covered content got viewDidUnhide in the key turn: AppKit's hidden-ancestor walk")
        for (pane, host) in zip(covered, hosts) {
            #expect(screen.root.context.hosts[pane] === host, "\(pane.rawValue) came back with a new host")
        }
        for (pane, probe) in zip(covered, probes) {
            #expect(!probe.isParkedOrHasParkedAncestor, "\(pane.rawValue)'s content is still parked after the unzoom")
            #expect(probe.parkingChanges >= 2, "\(pane.rawValue)'s content heard \(probe.parkingChanges) parking changes, not the cover and the uncover")
        }
        screen.land()
        for (pane, host) in zip(covered, hosts) {
            #expect(!host.isHidden && host.layer?.opacity == 1, "\(pane.rawValue) does not show after the unzoom: opacity \(host.layer?.opacity ?? -1)")
        }
    }
}
#endif
