#if os(iOS)
@testable import CmuxMobileShellUI
import Testing

@Suite struct OnboardingPageTrackTests {
    @Test func stagesOccupyOrderedHorizontalPages() {
        let pageWidth = 400.0

        #expect(onboardingPageOffset(for: .agents, pageWidth: pageWidth) == 0)
        #expect(onboardingPageOffset(for: .notifications, pageWidth: pageWidth) == -400)
        #expect(onboardingPageOffset(for: .connect, pageWidth: pageWidth) == -800)
    }

    @Test func advancingAgainAfterReturningToFirstPageUsesForwardTrackMotion() {
        let pageWidth = 400.0
        let stages: [OnboardingStage] = [.agents, .notifications, .agents, .notifications]
        let offsets = stages.map {
            onboardingPageOffset(for: $0, pageWidth: pageWidth)
        }

        #expect(offsets == [0, -400, 0, -400])
    }
}
#endif
