import CmuxMobileShellModel
import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileOnboardingGateTests {
    @Test(arguments: [
        MobileOnboardingProgress.welcome,
        MobileOnboardingProgress.connect,
    ])
    func showsEveryIncompleteMilestone(_ progress: MobileOnboardingProgress) {
        #expect(progress.shouldShowOnboarding)
    }

    @Test func skipsCompletedOnboarding() {
        #expect(!MobileOnboardingProgress.complete.shouldShowOnboarding)
    }

}
