@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextOnboarding
import CmuxNextSettings
import Testing

/// Lawrence 2026-10-09: no onboarding window, no import flow except import
/// from a browser. The wizard and every action that opened it are gone; the
/// one window host is left for two single tools, Import from Browser and
/// Computer Use setup, each alone, ended by its own button.
@MainActor
@Suite struct OnboardingWizardRemovedTests {
    static let removed: [ActionID] = [
        "onboarding.continueSetup", "palette.welcomeChecklist", "importAndSync.show", "palette.importClassicSessions",
        "palette.onboardingGallery",
    ]

    @Test func noActionOpensTheWizard() {
        let registry = ActionBindingCoverageTests.boundServices().registry
        for id in Self.removed {
            #expect(!ActionCatalog.all.contains { $0.id == id }, "\(id) is not an action")
            #expect(!SettingsSchema.actions(in: .general).contains(id), "\(id) is not in Settings")
            #expect(!registry.isBound(id), "\(id) has no handler")
        }
    }

    @Test func theWindowHostsOnlyImportFromBrowserAndComputerUse() {
        #expect(OnboardingModel.Step.allCases == [.importData, .computerUse])
    }

    @Test func eachToolOpensAloneAndItsPrimaryButtonEndsIt() {
        let model = OnboardingModel(services: MockOnboardingServices(), step: .computerUse)
        #expect(model.steps == [.computerUse])
        var ended: Bool?
        model.onEnd = { ended = $0 }
        model.next()
        #expect(ended == true, "Done ends the tool's window")
        let importer = OnboardingModel(services: MockOnboardingServices(), step: .importData)
        #expect(importer.steps == [.importData])
        var skipped: Bool?
        importer.onEnd = { skipped = $0 }
        importer.skipStep()
        #expect(skipped != nil, "Skip ends the Import from Browser window")
    }
}
