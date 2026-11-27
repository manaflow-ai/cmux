import AppKit
import CmuxNextDesign
@testable import CmuxNextApp
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A split or a close is one commit, so a terminal's TUI resizes one time, in the frame that shows
/// the change. The key's turn tells no pane's content a size it will rest at, resizes no content and
/// holds no terminal grid: the screen still shows the layout before the change. The first frame tick
/// shows the change and gives each pane whose size changes its final size, once, so a terminal sends
/// its final PTY grid there and nothing after it.
///
/// Contract this suite pins: `PaneMotionTargeting.paneMotionWillRest(sizeChange:)` (CmuxNextDesign) is a
/// spring's notice (a keyboard resize, the same panes going to another ratio); a split or a close sends
/// none, and each content view takes one new size, the size it rests at, in the first frame tick.
/// Frames step at a fixed 120 Hz dt; the display link never ticks.
@MainActor
@Suite(.closesItsWindows)
struct EarlyTerminalGridTests {
    /// A pane's content that records what the layout tells it and each size it takes.
    final class Content: NSView, PaneMotionSettling, PaneMotionTargeting {
        var restingSizes: [CGSize] = []
        var settled = 0
        /// Each size with an area that the view took, in order (a pane not placed yet has none).
        var sizes: [CGSize] = []
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size, newSize.width > 0, newSize.height > 0 { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }
        func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
            restingSizes.append(CGSize(width: bounds.width + sizeChange.width, height: bounds.height + sizeChange.height))
            return .top
        }
        func paneMotionDidSettle() { settled += 1 }
    }

    final class Panes: LayoutPaneContentProvider {
        var contents: [PaneID: Content] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let content = Content()
            contents[pane] = content
            return content
        }
    }

    static let dt = 1.0 / 120

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var holds: [Bool] = []

        init(_ tree: SplitNode) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s",
                                focusedPane: tree.panes.first)
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.onTerminalGridHold = { [weak self] in self?.holds.append($0) }
        }

        func show(_ tree: SplitNode) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
            root.syncWithModel()
        }

        /// Steps until nothing moves (at most 2 s); fails when a frame holds the grids.
        func settle(_ heldFrames: inout Int) {
            for _ in 1...240 {
                let moving = root.advanceFrame(EarlyTerminalGridTests.dt)
                if root.holdsTerminalGrids { heldFrames += 1 }
                if !moving { return }
            }
        }
    }

    static let pair: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    static let pairSplit: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                             b: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
    static let row: SplitNode = .split("r1", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                       b: .split("r2", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))

    /// Cmd-D: the key's turn tells no pane of the chain a resting size, resizes no content and holds
    /// no grid. The one frame tick that shows the split gives every pane of the chain its final size,
    /// once, and no frame after it resizes one or holds the grids.
    @Test func aSplitSizesEveryPaneOnceInTheFrameThatShowsIt() throws {
        let screen = Screen(Self.pair)
        defer { screen.window.closeAfterTest() }
        let view = try #require(screen.root.screenViews["s"])
        let changes = screen.model.splitSizingChanges(splitting: "p2", axis: .horizontal)
        _ = screen.model.showSplitSizing(changes)
        for content in screen.provider.contents.values { content.sizes.removeAll() }
        screen.show(Self.pairSplit)
        // The key's turn: the screen still shows the layout before the split.
        #expect(!screen.root.holdsTerminalGrids, "the split's turn holds the grids")
        #expect(!view.hasMotion, "the split put a pane on a spring")
        for pane: PaneID in ["p1", "p2", "p3"] {
            let content = try #require(screen.provider.contents[pane])
            #expect(content.restingSizes.isEmpty, "\(pane) was told \(content.restingSizes.count) resting sizes in the key's turn")
            #expect(content.sizes.isEmpty, "\(pane)'s content took \(content.sizes) in the key's turn")
        }
        // The frame tick that shows the split.
        #expect(!screen.root.advanceFrame(Self.dt), "the frame that shows the split left something moving")
        #expect(!screen.root.holdsTerminalGrids, "the frame that shows the split holds the grids")
        var heldFrames = 0
        screen.settle(&heldFrames)
        #expect(heldFrames == 0, "\(heldFrames) frames held the grids")
        #expect(screen.holds.allSatisfy { !$0 }, "hold changes: \(screen.holds)")
        for pane: PaneID in ["p1", "p2", "p3"] {
            let content = try #require(screen.provider.contents[pane]), host = try #require(screen.root.context.hosts[pane])
            #expect(content.restingSizes.isEmpty, "\(pane) was told \(content.restingSizes) for a change with no spring")
            #expect(content.sizes == [host.contentRect.size], "\(pane): took \(content.sizes), rests at \(host.contentRect.size)")
        }
    }

    /// Cmd-W on p2's last tab: the key's turn tells the panes that grow no resting size, resizes no
    /// content and holds no grid, and the closed pane still shows. The one frame tick that shows the
    /// close hides the closed pane and gives each pane that grows its final size, once.
    @Test func aCloseSizesTheGrowingPanesOnceInTheFrameThatShowsIt() throws {
        let screen = Screen(Self.row)
        defer { screen.window.closeAfterTest() }
        let view = try #require(screen.root.screenViews["s"])
        var heldFrames = 0
        screen.settle(&heldFrames)
        let closed = try #require(screen.root.context.hosts["p2"])
        for content in screen.provider.contents.values {
            content.restingSizes.removeAll()
            content.sizes.removeAll()
        }
        _ = try #require(screen.model.showPaneClose("p2"))
        screen.root.syncWithModel()
        // The key's turn: the screen still shows the layout before the close.
        #expect(!screen.root.holdsTerminalGrids, "the close's turn holds the grids")
        #expect(!view.hasMotion, "the close put a pane on a spring")
        #expect(!closed.isHidden, "the closed pane went before the frame that shows the close")
        for pane: PaneID in ["p1", "p3"] {
            let content = try #require(screen.provider.contents[pane])
            #expect(content.restingSizes.isEmpty, "\(pane) was told \(content.restingSizes.count) resting sizes in the key's turn")
            #expect(content.sizes.isEmpty, "\(pane)'s content took \(content.sizes) in the key's turn")
        }
        // The frame tick that shows the close.
        #expect(!screen.root.advanceFrame(Self.dt), "the frame that shows the close left something moving")
        #expect(closed.isHidden, "the frame that shows the close still shows the closed pane")
        heldFrames = 0
        screen.settle(&heldFrames)
        #expect(heldFrames == 0, "\(heldFrames) frames held the grids")
        for pane: PaneID in ["p1", "p3"] {
            let content = try #require(screen.provider.contents[pane]), host = try #require(screen.root.context.hosts[pane])
            #expect(content.restingSizes.isEmpty, "\(pane) was told \(content.restingSizes) for a change with no spring")
            #expect(content.sizes == [host.contentRect.size], "\(pane): took \(content.sizes), rests at \(host.contentRect.size)")
        }
    }

    /// A second Cmd-D before a frame showed the first: the screen shows only the layout of the two
    /// splits, so each pane's content takes one size, the size it rests at, and never the size that
    /// the first split alone gave it.
    @Test func aSecondSplitBeforeTheFirstShowedSizesEveryPaneOnce() throws {
        let screen = Screen(Self.pair)
        defer { screen.window.closeAfterTest() }
        for content in screen.provider.contents.values { content.sizes.removeAll() }
        _ = screen.model.showSplitSizing(screen.model.splitSizingChanges(splitting: "p2", axis: .horizontal))
        screen.show(Self.pairSplit)
        let triple: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                       b: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("p2"),
                                                 b: .split("m", axis: .horizontal, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4"))))
        _ = screen.model.showSplitSizing(screen.model.splitSizingChanges(splitting: "p3", axis: .horizontal))
        screen.show(triple)
        // The one frame tick that shows the two splits.
        #expect(!screen.root.advanceFrame(Self.dt), "the frame that shows the splits left something moving")
        var heldFrames = 0
        screen.settle(&heldFrames)
        #expect(heldFrames == 0)
        for pane: PaneID in ["p1", "p2", "p3", "p4"] {
            let content = try #require(screen.provider.contents[pane]), host = try #require(screen.root.context.hosts[pane])
            #expect(content.restingSizes.isEmpty, "\(pane) was told \(content.restingSizes) for a change with no spring")
            #expect(content.sizes == [host.contentRect.size], "\(pane): took \(content.sizes), rests at \(host.contentRect.size)")
        }
    }
}
