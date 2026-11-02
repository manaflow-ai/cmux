import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

@MainActor
@Suite(.closesItsWindows)
struct PaneMotionVariantTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// Owns one manually stepped screen; variants are injected without changing shared debug settings.
    final class Screen {
        let panes = Panes()
        let context: LayoutViewContext
        let view: ScreenContentView
        let window: NSWindow

        init(_ tree: SplitNode, variant: PaneMotionVariant, reduceMotion: Bool = false) {
            let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))],
                                    activeScreenID: "s", focusedPane: "p1")
            context = LayoutViewContext(model: model, provider: panes)
            context.reduceMotionOverride = reduceMotion
            context.livePanes = Set(tree.panes)
            view = ScreenContentView(screenID: "s", layout: .splits(tree), context: context, paneMotionVariant: { variant })
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = view
            view.reconcile(animated: false)
        }

        func zoom() {
            context.livePanes = ["p1"]
            view.update(layout: .splits(.leaf("p1")), zoomed: true, animated: true)
        }

        func close() {
            context.livePanes = ["p1"]
            view.update(layout: .splits(.leaf("p1")), animated: true)
        }

        @discardableResult
        func step() -> Bool { view.step(1.0 / 120) }
    }

    static let split = SplitNode.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))

    @Test(arguments: PaneMotionVariant.allCases)
    func expandLaysOutLiveAndSettles(_ variant: PaneMotionVariant) throws {
        let screen = Screen(Self.split, variant: variant)
        screen.zoom()
        let target = try #require(screen.view.geometry.panes["p1"])
        var sizes: Set<CGFloat> = []
        for _ in 0..<120 {
            screen.step()
            let shown = try #require(screen.view.paneFrames["p1"]?.rect)
            #expect(screen.context.hosts["p1"]?.frame == screen.view.displayedFrame(of: "p1"), "the expanding pane is not laid out at its spring rect")
            sizes.insert(shown.width)
        }
        #expect(sizes.count >= 5, "the expanding pane laid out \(sizes.count) widths")
        #expect(screen.view.paneFrames["p1"]?.rect == target)
        #expect(screen.context.hosts["p1"]?.frame == screen.view.displayedFrame(of: "p1"))
        #expect(screen.view.zoomMotion.covered.isEmpty)
        #expect(!screen.step(), "a settled pane prototype kept requesting animation frames")
    }

    @Test(arguments: PaneMotionVariant.allCases)
    func closeGrowsTheNeighbourLiveAndReleasesTheClosedHost(_ variant: PaneMotionVariant) throws {
        let screen = Screen(Self.split, variant: variant)
        screen.close()
        let target = try #require(screen.view.geometry.panes["p1"])
        #expect(screen.context.hosts["p2"] == nil, "a prototype retained the closed pane's native content")
        var sizes: Set<CGFloat> = []
        for _ in 0..<120 {
            screen.step()
            let shown = try #require(screen.view.paneFrames["p1"]?.rect)
            #expect(screen.context.hosts["p1"]?.frame == screen.view.displayedFrame(of: "p1"), "the growing pane is not laid out at its spring rect")
            sizes.insert(shown.width)
        }
        #expect(sizes.count >= 5, "the growing pane laid out \(sizes.count) widths")
        #expect(screen.view.paneFrames["p1"]?.rect == target)
        #expect(!screen.step())
    }

    @Test func crispExpandAndCloseMoveFartherInTheFirstFrameThanCurrent() throws {
        for zooming in [true, false] {
            let current = Screen(Self.split, variant: .standard)
            let crisp = Screen(Self.split, variant: .crisp)
            if zooming { current.zoom(); crisp.zoom() } else { current.close(); crisp.close() }
            current.step()
            crisp.step()
            let currentWidth = try #require(current.view.paneFrames["p1"]?.width.value)
            let crispWidth = try #require(crisp.view.paneFrames["p1"]?.width.value)
            #expect(crispWidth > currentWidth)
        }
    }

    @Test(arguments: PaneMotionVariant.allCases)
    func reduceMotionSnapsEveryVariant(_ variant: PaneMotionVariant) throws {
        for zooming in [true, false] {
            let screen = Screen(Self.split, variant: variant, reduceMotion: true)
            if zooming { screen.zoom() } else { screen.close() }
            #expect(screen.view.paneFrames["p1"]?.rect == screen.view.geometry.panes["p1"])
            #expect(!screen.step())
        }
    }

    @Test func debugChoiceIsInertUntilItsStoreIsActivatedAndResetsToCurrent() {
        let store = TunableStore()
        let choice = LayoutTunables.paneMotionVariant
        store.register(LayoutTunables.all)
        store.set(choice.key, PaneMotionVariant.crisp.tunableValue)
        #expect(choice.value(in: store) == .standard)
        store.activate(file: nil)
        #expect(choice.value(in: store) == .crisp)
        store.reset([choice.key])
        #expect(choice.value(in: store) == .standard)
    }
}
