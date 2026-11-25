import AppKit
import CmuxNextBridge
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// RESIZE KEYS (lead 2026-11-02 21:1xZ, Lawrence's case "the first frame of the move is in the next refresh after the
/// key"): a keyboard resize press must start its spring in the key's own turn, so the very next display frame moves.
/// The press wrote the model and the layout heard it through its observation task, a later main-actor turn: a display
/// tick that ran first moved nothing, and the first moved frame came a refresh later.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeFirstFrameTests {
    typealias Harness = PaneResizeGestureTests.Harness

    @Test(arguments: [LayoutDirection.left, .right])
    func theDisplayFrameAfterThePressMoves(direction: LayoutDirection) throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let host = try #require(harness.root.context.hosts["p2"])
        let before = host.frame
        #expect(PaneResize.press("p2", direction, model: harness.model, view: harness.root))
        // No await and no sync: the next display frame comes right after the key's turn.
        harness.frame()
        #expect(host.frame != before, "the first display frame after the press did not move the pane")
    }
}
