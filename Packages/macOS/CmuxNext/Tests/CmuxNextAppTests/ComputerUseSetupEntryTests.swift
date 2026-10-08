@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextOnboarding
import CmuxNextPages
import Testing

/// Computer Use Setup is one shared action: the palette and CLI run it, the
/// Settings page may run it and its two grant actions, and onboarding offers
/// the step even before any helper runs (Computer Use off, a fresh Mac).
@MainActor
@Suite struct ComputerUseSetupEntryTests {
    @Test func theSetupActionIsBoundNotAPlaceholder() {
        let services = ActionBindingCoverageTests.boundServices()
        for id in ["palette.computerUse.setup", "palette.computerUse.accessibility", "palette.computerUse.screenRecording"] {
            #expect(services.registry.unavailableReason(for: ActionID(rawValue: id)) == nil, "\(id) runs")
        }
    }

    @Test func theSettingsPageMayRunTheSetupActions() {
        for id in ["palette.computerUse.setup", "palette.computerUse.accessibility", "palette.computerUse.screenRecording"] {
            #expect(PageDescriptor.settings.actions.contains(id), "\(id) from the Settings card")
        }
    }

    @Test func onboardingOffersTheStepWithoutARunningHelper() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let onboarding = AppOnboardingServices(owner: services.onboarding)
        #expect(onboarding.computerUsePermissions != nil, "the step shows with Computer Use off")
    }
}

extension ComputerUseSetupEntryTests {
    /// Asking for the step while another onboarding window shows rebuilds it with the step.
    @Test func askingForAStepTheOpenWindowLacksRebuildsIt() {
        let firstRun: [OnboardingModel.Step] = [.accounts, .importData]
        #expect(OnboardingService.reusesWindow(showing: firstRun, for: nil))
        #expect(OnboardingService.reusesWindow(showing: firstRun, for: .importData))
        #expect(!OnboardingService.reusesWindow(showing: firstRun, for: .computerUse))
    }
}
