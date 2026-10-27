import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// A window live-resize event of a screen at rest (p03-rendering-115, DC16): the screen computes its geometry at
/// the new size and sets frames only on the panes whose rects changed, with no reconcile (no host, divider or
/// container made, moved or restyled), as Chromium's `views::View::SetBoundsRect` then `Layout()` does
/// (ui/views/view.cc). The frames it lands on are the ones a full reconcile at that size gives.
@MainActor @Suite(.serialized)
struct ScreenResizeInPlaceTests {
    /// Pane content that counts the times its size changed (a terminal's grid report, a page's resize).
    final class Leaf: NSView {
        var resizes = 0
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { resizes += 1 }
            super.setFrameSize(newSize)
        }
    }

    final class Panes: LayoutPaneContentProvider {
        var leaves: [PaneID: Leaf] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let leaf = Leaf()
            leaves[pane] = leaf
            return leaf
        }
    }

    /// STRESS's 4 x 3 grid of 12 panes in a window `width` points wide, laid out once.
    final class Fixture {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        static let height: CGFloat = 1000

        init(width: CGFloat) {
            model = LayoutModel(screens: PaneMotionBench.grid(4, 3), activeScreenID: "s", focusedPane: PaneID("p0-0"))
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: Self.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }

        var screen: ScreenContentView? { root.screenViews["s"] }
        var hostFrames: [PaneID: CGRect] { root.context.hosts.mapValues(\.frame) }

        /// The window's content `width` points wide, laid out as AppKit lays out a live-resize event.
        func resize(width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: Self.height))
            root.layoutSubtreeIfNeeded()
        }
    }

    @Test func aOnePointWidthChangeOfTwelvePanesSetsOnlyTheChangedPanesAndReconcilesNone() throws {
        let fixture = Fixture(width: 1600)
        defer { fixture.window.close() }
        let screen = try #require(fixture.screen)
        #expect(screen.paneFrames.count == 12, "the grid has \(screen.paneFrames.count) panes")
        let before = fixture.hostFrames
        let reconciles = screen.reconcilePasses, inPlace = screen.resizesInPlace
        let resizesBefore = fixture.provider.leaves.mapValues(\.resizes)

        fixture.resize(width: 1601)

        let after = fixture.hostFrames
        #expect(screen.reconcilePasses == reconciles, "the resize ran \(screen.reconcilePasses - reconciles) reconciles")
        #expect(screen.resizesInPlace == inPlace + 1, "\(screen.resizesInPlace - inPlace) resizes in place")
        #expect(before != after, "a 1 pt wider window moved no pane")
        for (pane, leaf) in fixture.provider.leaves {
            let sized = leaf.resizes - (resizesBefore[pane] ?? 0)
            let resized = before[pane]?.size != after[pane]?.size
            if resized {
                #expect(sized > 0, "\(pane): its size changed and its content kept its size")
            } else {
                #expect(sized == 0, "\(pane): its size kept and its content resized \(sized) times")
            }
        }
        // The frames a full reconcile at the new size gives.
        let fresh = Fixture(width: 1601)
        defer { fresh.window.close() }
        #expect(after == fresh.hostFrames, "in place: \(after.sorted { $0.key < $1.key }), reconciled: \(fresh.hostFrames.sorted { $0.key < $1.key })")
        #expect(screen.dividerFrames.mapValues(\.targetRect) == fresh.screen?.dividerFrames.mapValues(\.targetRect))
    }

    @Test func aResizeBackLandsOnTheFramesItLeftWithNoReconcile() throws {
        let fixture = Fixture(width: 1600)
        defer { fixture.window.close() }
        let screen = try #require(fixture.screen)
        let start = fixture.hostFrames, reconciles = screen.reconcilePasses
        // A live-resize drag out and back, one event per point.
        for width in stride(from: CGFloat(1601), through: 1640, by: 1) { fixture.resize(width: width) }
        for width in stride(from: CGFloat(1639), through: 1600, by: -1) { fixture.resize(width: width) }
        #expect(fixture.hostFrames == start, "the drag back did not land where it started")
        #expect(screen.reconcilePasses == reconciles, "the drag ran \(screen.reconcilePasses - reconciles) reconciles")
    }

    /// A resize while a split springs keeps the reconcile: the spring retargets (or snaps in a live resize).
    @Test func aResizeWhilePanesSpringReconciles() throws {
        let fixture = Fixture(width: 1600)
        defer { fixture.window.close() }
        let screen = try #require(fixture.screen)
        fixture.model.apply(screens: PaneMotionBench.split(4, 3, axis: .horizontal))
        fixture.root.syncWithModel()
        for _ in 0..<2 { _ = fixture.root.advanceFrame(1.0 / 120) }
        try #require(screen.hasMotion, "the split was not springing")
        let reconciles = screen.reconcilePasses, inPlace = screen.resizesInPlace
        fixture.resize(width: 1601)
        #expect(screen.reconcilePasses > reconciles, "a resize mid-spring did not reconcile")
        #expect(screen.resizesInPlace == inPlace, "a resize mid-spring took the in-place path")
    }
}
