import CmuxMobileShellModel
import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileOnboardingGateTests {
    @Test(arguments: [
        MobileOnboardingProgress.welcome,
        MobileOnboardingProgress.connect,
    ])
    func showsEveryIncompleteMilestone(_ progress: MobileOnboardingProgress) {
        #expect(MobileOnboardingGate.shouldShowOnboarding(progress: progress))
    }

    @Test func skipsCompletedOnboarding() {
        #expect(!MobileOnboardingGate.shouldShowOnboarding(progress: .complete))
    }
}
