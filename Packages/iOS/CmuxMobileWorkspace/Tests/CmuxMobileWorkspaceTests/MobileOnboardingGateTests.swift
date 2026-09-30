import CmuxMobileShellModel
import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileOnboardingGateTests {
    @Test(arguments: [
        MobileOnboardingProgress.welcome,
        MobileOnboardingProgress.connect,
    ])
    func showsEveryIncompleteMilestoneWhenSignedIn(_ progress: MobileOnboardingProgress) {
        #expect(progress.shouldShowOnboarding(
            isAuthenticated: true,
            isRestoringSession: false
        ))
    }

    @Test func skipsCompletedOnboarding() {
        #expect(!MobileOnboardingProgress.complete.shouldShowOnboarding(
            isAuthenticated: true,
            isRestoringSession: false
        ))
    }

    @Test(arguments: [
        MobileOnboardingProgress.welcome,
        MobileOnboardingProgress.connect,
        MobileOnboardingProgress.complete,
    ])
    func neverShowsSignedOut(_ progress: MobileOnboardingProgress) {
        #expect(!progress.shouldShowOnboarding(
            isAuthenticated: false,
            isRestoringSession: false
        ))
    }

    @Test(arguments: [
        MobileOnboardingProgress.welcome,
        MobileOnboardingProgress.connect,
    ])
    func neverShowsWhileSessionIsRestoring(_ progress: MobileOnboardingProgress) {
        #expect(!progress.shouldShowOnboarding(
            isAuthenticated: true,
            isRestoringSession: true
        ))
    }
}
