#if os(iOS)
@testable import CmuxMobileShellUI
import Testing

@Suite struct OnboardingPageTrackTests {
    @Test func stagesOccupyOrderedHorizontalPages() {
        let pageWidth = 400.0

        #expect(OnboardingStage.agents.pageOffset(pageWidth: pageWidth) == 0)
        #expect(OnboardingStage.notifications.pageOffset(pageWidth: pageWidth) == -400)
        #expect(OnboardingStage.connect.pageOffset(pageWidth: pageWidth) == -800)
    }

    @Test func advancingAgainAfterReturningToFirstPageUsesForwardTrackMotion() {
        let pageWidth = 400.0
        let stages: [OnboardingStage] = [.agents, .notifications, .agents, .notifications]
        let offsets = stages.map {
            $0.pageOffset(pageWidth: pageWidth)
        }

        #expect(offsets == [0, -400, 0, -400])
    }
}
#endif
