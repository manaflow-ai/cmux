import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import CmuxNextSidebar
import Testing

/// Customize Appearance… (`appearance.customize`): one action reached from the palette, the View
/// menu and the sidebar. R82 commit 6: it opens Settings on Appearance (the React page), whose
/// sliders preview live in every window; the floating studio panel went with the Swift UI.
@MainActor
@Suite(.serialized)
struct CustomizeAppearanceTests {
    @Test func customizeAppearanceIsBoundOnThePaletteAndMenu() throws {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(services.registry.isBound("appearance.customize"))
        let descriptor = try #require(services.registry.descriptor(for: "appearance.customize"))
        #expect(descriptor.surfaces.contains(.palette) && descriptor.surfaces.contains(.menu))
        // Appearance itself offers no button that opens Appearance.
        #expect(!SettingsSchema.actions(in: .appearance).contains("appearance.customize"))
        withExtendedLifetime(services) {}
    }

    /// The route the action opens is Settings > Appearance.
    @Test func customizeAppearanceOpensTheAppearanceSection() {
        #expect(SettingsWindowService.route(section: .appearance, setting: nil) == "#/settings/appearance")
    }

    /// Customize Appearance is a sidebar item users can add (it runs the
    /// same action); the default bottom band leaves it out (decision S11).
    @Test func theSidebarItemRunsTheActionAndIsNotInTheDefaultBand() throws {
        #expect(SidebarBridge.builtInActions[.customize] == "appearance.customize")
        let bottom = try #require(SidebarLayoutDocument.defaults.section(SidebarLayoutDocument.bottomSectionID))
        #expect(!bottom.items.contains { $0.ref == .builtIn(.customize) })
        #expect(SidebarBuiltIn.allCases.contains(.customize))
        #expect(SidebarBuiltIn.allCases.allSatisfy { SidebarBridge.builtInActions[$0] != nil })
    }
}
