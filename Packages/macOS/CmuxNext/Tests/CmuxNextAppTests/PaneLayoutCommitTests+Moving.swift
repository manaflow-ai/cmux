@testable import CmuxNextLayout
import Testing

/// Whether the fixture of `PaneLayoutCommitTests` asks for the move of its panes at a layout change
/// (`PaneCommitMotion`). It is off unless a test sets it for its own task, so each test of that suite runs as it did
/// before the move was there.
enum PaneLayoutCommitMove {
    @TaskLocal static var isOn = false
}

/// `PaneLayoutCommitTests` a second time, with the move of the panes on. The two tests that hold what a layout change
/// shows run again as they are: each frame still shows one whole layout, the frame that shows a change is the first
/// one after it, each pane's content is at the rect that its pane gives it, and no content takes more than one size.
/// One thing is read in another way with the move on: a pane that a close took out or that a zoom covers shows to
/// the motion's end, so a frame shows a layout when it has that layout's panes at their rest rects, and such a pane
/// too. An unzoom of this fixture's content shows in one frame: the content gives no last frame.
///
/// The suite's other tests do not run a second time here: they hold a closed pane's teardown, a close that is taken
/// back, a close that resizes no pane, the strip's camera and the content's size asks.
extension PaneLayoutCommitTests {
    @Test(arguments: changes)
    func withTheMoveOnALayoutChangeShowsInOneFrame(_ change: Change) throws {
        try PaneLayoutCommitMove.$isOn.withValue(true) { try aLayoutChangeShowsInOneFrame(change) }
    }

    @Test(arguments: [0, 1])
    func withTheMoveOnTwoLayoutChangesShowOnlyWholeLayouts(framesBetween: Int) throws {
        try PaneLayoutCommitMove.$isOn.withValue(true) { try twoLayoutChangesShowOnlyWholeLayouts(framesBetween: framesBetween) }
    }
}
