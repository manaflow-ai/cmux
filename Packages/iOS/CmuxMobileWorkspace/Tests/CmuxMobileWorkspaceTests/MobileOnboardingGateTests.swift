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

    @Test func connectionCompletesOnlyTheConnectionMilestone() {
        #expect(!MobileOnboardingProgress.welcome.shouldCompleteAfterConnection(isConnected: true))
        #expect(MobileOnboardingProgress.connect.shouldCompleteAfterConnection(isConnected: true))
        #expect(!MobileOnboardingProgress.complete.shouldCompleteAfterConnection(isConnected: true))
        #expect(!MobileOnboardingProgress.connect.shouldCompleteAfterConnection(isConnected: false))
    }
}
