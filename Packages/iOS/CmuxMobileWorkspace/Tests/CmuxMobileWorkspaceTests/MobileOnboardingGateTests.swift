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

    @Test func connectionCompletesOnlyTheConnectionMilestone() {
        #expect(!MobileOnboardingGate.shouldCompleteAfterConnection(progress: .welcome, isConnected: true))
        #expect(MobileOnboardingGate.shouldCompleteAfterConnection(progress: .connect, isConnected: true))
        #expect(!MobileOnboardingGate.shouldCompleteAfterConnection(progress: .complete, isConnected: true))
        #expect(!MobileOnboardingGate.shouldCompleteAfterConnection(progress: .connect, isConnected: false))
    }
}
