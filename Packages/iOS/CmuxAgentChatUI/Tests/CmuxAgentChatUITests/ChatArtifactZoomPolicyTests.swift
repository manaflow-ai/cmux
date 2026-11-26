import Testing

@testable import CmuxAgentChatUI

@Suite("Chat artifact zoom policy")
struct ChatArtifactZoomPolicyTests {
    @Test("fitted images double tap to three times and back")
    func doubleTapToggle() {
        let policy = ChatArtifactZoomPolicy()

        #expect(policy.minimumScale == 1)
        #expect(policy.maximumScale == 8)
        #expect(policy.scaleAfterDoubleTap(currentScale: 1) == 3)
        #expect(policy.scaleAfterDoubleTap(currentScale: 3) == 1)
        #expect(policy.scaleAfterDoubleTap(currentScale: 7) == 1)
    }

    @Test("paging threshold tolerates UIScrollView scale noise")
    func minimumThreshold() {
        let policy = ChatArtifactZoomPolicy()

        #expect(policy.isAtMinimum(1))
        #expect(policy.isAtMinimum(1.005))
        #expect(!policy.isAtMinimum(1.02))
    }

    @Test("a horizontal image swipe at one-times zoom pages to the adjacent file")
    func fittedImageSwipeBelongsToPager() throws {
        let policy = ChatArtifactZoomPolicy()
        var pager = ChatArtifactPageControllerState(
            paths: ["/screenshots/shot-03.png", "/guide.md"],
            selectedPath: "/screenshots/shot-03.png"
        )

        #expect(policy.horizontalSwipeOwner(at: 1) == .pager)
        let adjacentPath = try #require(pager.path(after: pager.selectedPath))
        let didTransition = pager.completeTransition(to: adjacentPath)
        #expect(didTransition)
        #expect(pager.selectedPath == "/guide.md")

        #expect(policy.horizontalSwipeOwner(at: 3) == .image)
    }
}
