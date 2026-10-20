@testable import CmuxNextApp
import CmuxNextLayout
import CoreGraphics
import Testing

@MainActor
struct TerminalLinkBrowserPlacementTests {
    @Test func reusesTheNearestPaneToTheRightBeforeCreatingASplit() {
        let source: PaneID = "source"
        let right: PaneID = "right"
        let layout = ScreenLayout.splits(
            .split("root", axis: .horizontal, ratio: 0.5, a: .leaf(source), b: .leaf(right))
        )
        let frames: [PaneID: CGRect] = [
            source: CGRect(x: 0, y: 0, width: 400, height: 600),
            right: CGRect(x: 400, y: 0, width: 400, height: 600),
        ]

        #expect(TerminalLinkBrowserPlacement().destination(for: source, in: layout, frames: frames) == .reuse(right))
    }
}
