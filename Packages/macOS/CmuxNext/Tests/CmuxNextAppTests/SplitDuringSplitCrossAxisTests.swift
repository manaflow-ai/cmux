import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A split of a pane that is still moving starts the new pane where the split pane shows, on both axes (RESIZE
/// VIDEOS O1, STATUS: split-during-split, film frames 176-178). Cmd-D grows a third column in from the right; a
/// Shift-Cmd-D on that new pane 16 frames later split it down while the column still moved left. The new pane rode
/// the split pane's bottom edge (the split's axis) but took its column's REST x and width: it showed 31 pt left of
/// the pane above it and overlapped the left neighbour by 30 pt, closing over 12 frames. The new pane (and the new
/// divider between them) now start at the split pane's shown x and width, moving at its velocity, so the column
/// moves as one. The test is the clock (120 Hz).
@MainActor
@Suite(.closesItsWindows)
struct SplitDuringSplitCrossAxisTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let pair: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    static let three: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                         b: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
    /// `three` after Shift-Cmd-D on p3: p3 over p4.
    static let threeDown: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                             b: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("p2"),
                                                       b: .split("d", axis: .vertical, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4"))))

    @Test func aSplitDownOfAMovingPaneStartsUnderItAndMovesWithIt() throws {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(Self.pair))], activeScreenID: "s", focusedPane: "p2")
        model.splitSizingOverride = .even
        let root = LayoutRootView(model: model, contentProvider: Panes())
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        let screen = try #require(root.screenViews["s"])
        func show(_ tree: SplitNode) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
            root.syncWithModel()
        }

        // Cmd-D on p2 (even sizing: p2 shrinks and p3 grows in from the right), then 16 frames of it.
        _ = model.showSplitSizing(model.splitSizingChanges(splitting: "p2", axis: .horizontal))
        show(Self.three)
        for _ in 0..<16 { root.advanceFrame(1.0 / 120) }
        let moving = try #require(screen.paneFrames["p3"])
        #expect(abs(moving.rect.minX - moving.targetRect.minX) > 10, "p3 still moves sideways (\(moving.rect.minX) -> \(moving.targetRect.minX))")

        // Shift-Cmd-D on p3 while it moves.
        show(Self.threeDown)
        var worst: (frame: Int, dx: CGFloat, dw: CGFloat) = (0, 0, 0)
        var dividerWorst: CGFloat = 0
        for frame in 0..<300 {
            let upper = try #require(screen.displayedFrame(of: "p3")), lower = try #require(screen.displayedFrame(of: "p4"))
            let dx = abs(lower.minX - upper.minX), dw = abs(lower.width - upper.width)
            if max(dx, dw) > max(worst.dx, worst.dw) { worst = (frame, dx, dw) }
            if let divider = screen.dividerViews[.split("d")], !divider.isHidden {
                dividerWorst = max(dividerWorst, abs(divider.frame.midX - upper.midX))
            }
            if !root.advanceFrame(1.0 / 120) { break }
        }
        #expect(max(worst.dx, worst.dw) <= 1, "p4 left the column of p3: \(worst.dx) pt in x, \(worst.dw) pt in width at frame \(worst.frame)")
        #expect(dividerWorst <= 1, "the new divider left the column of p3 by \(dividerWorst) pt")
    }

    /// Guard (review of #31766): a split's new pane follows across the axis only the pane it split from, never a
    /// neighbour that touches the same line. p1 is full height beside a column whose p2 still grows down (p5 closed);
    /// Cmd-D on p1 puts p4 between them: p4 is full height from its first frame, not on p2's vertical spring.
    @Test func aSplitBesideAColumnThatMovesUpAndDownStaysAtRestAcrossTheAxis() throws {
        let start: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                      b: .split("c", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p5")))
        let closed: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
        let split: SplitNode = .split("r", axis: .horizontal, ratio: 0.5,
                                      a: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p4")), b: .leaf("p2"))
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(start))], activeScreenID: "s", focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: Panes())
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        let screen = try #require(root.screenViews["s"])
        func show(_ tree: SplitNode) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
            root.syncWithModel()
        }
        show(closed)
        for _ in 0..<4 { root.advanceFrame(1.0 / 120) }
        let growing = try #require(screen.paneFrames["p2"])
        #expect(abs(growing.rect.height - growing.targetRect.height) > 10, "p2 still grows down")
        show(split)
        var worst: CGFloat = 0
        for _ in 0..<300 {
            let p4 = try #require(screen.paneFrames["p4"])
            worst = max(worst, abs(p4.rect.minY - p4.targetRect.minY), abs(p4.rect.height - p4.targetRect.height))
            if !root.advanceFrame(1.0 / 120) { break }
        }
        #expect(worst <= 1, "p4 moved up or down with the neighbour column by \(worst) pt")
    }
}
