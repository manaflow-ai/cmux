import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A split while another pane motion still runs. A split is one commit of one layout: the spring an earlier ratio
/// change left in flight ends with it, every pane and divider rests on its place in the new layout, and the next frame
/// shows that layout whole. No pane starts where a moving pane shows and moves with it (a split's new pane once rode
/// the pane it split from, and showed beside its column while that column still moved). A split with nothing else in
/// motion, and two splits one frame apart, are in `PaneLayoutCommitTests`. The test is the clock (120 Hz).
@MainActor
@Suite(.closesItsWindows)
struct SplitDuringSplitCrossAxisTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// p1 is full height beside a column whose p2 still grows down (the divider between p2 and p5 is on its way to
    /// another ratio); Cmd-D on p1 puts p4 between them. The spring in flight ends with the split: every pane rests on
    /// its place in the new layout, the split's own turn moves nothing on screen, and the next frame shows the new
    /// layout, each pane at its rest rect.
    @Test func aSplitBesideAColumnThatStillMovesEndsThatMotionAndShowsInOneFrame() throws {
        let start: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                      b: .split("c", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p5")))
        // The same panes with the divider between p2 and p5 lower: no pane comes or goes, so p2 grows down on a spring.
        let grown: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                      b: .split("c", axis: .vertical, ratio: 0.7, a: .leaf("p2"), b: .leaf("p5")))
        let split: SplitNode = .split("r", axis: .horizontal, ratio: 0.5,
                                      a: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p4")),
                                      b: .split("c", axis: .vertical, ratio: 0.7, a: .leaf("p2"), b: .leaf("p5")))
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
        show(grown)
        for _ in 0..<4 { _ = root.advanceFrame(1.0 / 120) }
        let growing = try #require(screen.paneFrames["p2"])
        try #require(abs(growing.rect.height - growing.targetRect.height) > 10, "SET-UP: p2 does not grow down any more")
        let before: [PaneID] = ["p1", "p2", "p5"], after: [PaneID] = ["p1", "p2", "p4", "p5"]
        let shown = before.map { root.context.hosts[$0]?.frame }

        show(split)
        #expect(!screen.hasMotion, "the split left a pane or a divider on the spring that ran before it")
        for pane in after {
            let frame = try #require(screen.paneFrames[pane])
            #expect(frame.rect == frame.targetRect, "\(pane) does not rest on its place after the split: \(frame.rect) -> \(frame.targetRect)")
        }
        let shownInTheSplitsTurn = before.map { root.context.hosts[$0]?.frame }
        #expect(shownInTheSplitsTurn == shown, "the split's own turn moved a pane on screen: \(shown) -> \(shownInTheSplitsTurn)")
        #expect(!root.advanceFrame(1.0 / 120), "the frame that shows the split asks for more frames")
        for pane in after {
            #expect(root.context.hosts[pane]?.frame == screen.displayedFrame(of: pane),
                    "\(pane) is not at its rest rect in the frame that shows the split")
        }
    }
}
