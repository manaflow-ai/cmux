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
}
