import CmuxMobileShellModel
import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileOnboardingGateTests {
    @Test func welcomeShowsRegardlessOfAuthentication() {
        #expect(MobileOnboardingProgress.welcome.shouldShowOnboarding(isAuthenticated: false))
        #expect(MobileOnboardingProgress.welcome.shouldShowOnboarding(isAuthenticated: true))
    }

    @Test(arguments: [
        MobileOnboardingProgress.connect,
        MobileOnboardingProgress.push,
    ])
    func postWelcomeMilestonesWaitForSignIn(_ progress: MobileOnboardingProgress) {
        #expect(!progress.shouldShowOnboarding(isAuthenticated: false))
        #expect(progress.shouldShowOnboarding(isAuthenticated: true))
    }

    @Test func skipsCompletedOnboarding() {
        #expect(!MobileOnboardingProgress.complete.shouldShowOnboarding(isAuthenticated: true))
        #expect(!MobileOnboardingProgress.complete.shouldShowOnboarding(isAuthenticated: false))
    }
}
