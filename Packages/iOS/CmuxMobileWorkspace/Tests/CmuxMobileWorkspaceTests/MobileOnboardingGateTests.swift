import CmuxMobileShellModel
import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileOnboardingGateTests {
    @Test(arguments: [
        MobileOnboardingProgress.welcome,
        MobileOnboardingProgress.connect,
    ])
    func showsEveryIncompleteMilestoneWhenSignedIn(_ progress: MobileOnboardingProgress) {
        #expect(progress.shouldShowOnboarding(isAuthenticated: true))
    }

    @Test func skipsCompletedOnboarding() {
        #expect(!MobileOnboardingProgress.complete.shouldShowOnboarding(isAuthenticated: true))
    }

    @Test(arguments: [
        MobileOnboardingProgress.welcome,
        MobileOnboardingProgress.connect,
        MobileOnboardingProgress.complete,
    ])
    func neverShowsSignedOut(_ progress: MobileOnboardingProgress) {
        #expect(!progress.shouldShowOnboarding(isAuthenticated: false))
    }
}
