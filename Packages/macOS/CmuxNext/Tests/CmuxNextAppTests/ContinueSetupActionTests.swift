@testable import CmuxNextApp
import AppKit
import CmuxNextActions
import CmuxNextSettings
import Testing

/// "Continue setup" brings back a first run the person closed with "not
/// now": one action, offered in the Help menu, the palette and Settings,
/// all running the same handler.
@MainActor
@Suite struct ContinueSetupActionTests {
    static let id: ActionID = "onboarding.continueSetup"

    @Test func theHelpMenuThePaletteAndSettingsOfferTheSameAction() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == Self.id })
        #expect(descriptor.mainMenu == .help)
        #expect(descriptor.surfaces.contains(.palette))
        #expect(descriptor.surfaces.contains(.menu))
        #expect(SettingsSchema.actions(in: .general).contains(Self.id))
        #expect(ActionBindingCoverageTests.boundServices().registry.isBound(Self.id))
    }
}
