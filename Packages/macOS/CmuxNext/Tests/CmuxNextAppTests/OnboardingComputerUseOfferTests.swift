@testable import CmuxNextApp
import CmuxNextOnboarding
import Testing

/// Asking for the computer use step while another onboarding window shows
/// opens it: the window is rebuilt with the step. (The step itself is
/// offered without a running helper: ComputerUseSetupEntryTests.)
@MainActor
@Suite struct OnboardingComputerUseOfferTests {
    @Test func askingForAStepTheOpenWindowLacksRebuildsIt() {
        let firstRun: [OnboardingModel.Step] = [.accounts, .importData]
        #expect(OnboardingService.reusesWindow(showing: firstRun, for: nil))
        #expect(OnboardingService.reusesWindow(showing: firstRun, for: .importData))
        #expect(!OnboardingService.reusesWindow(showing: firstRun, for: .computerUse))
    }
}
