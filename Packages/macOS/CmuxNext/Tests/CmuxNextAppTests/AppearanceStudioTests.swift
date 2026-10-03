import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import CmuxNextSidebar
import Testing

/// The appearance studio (`appearance.customize`): one action reached from
/// the palette, the View menu and Settings > Appearance, and a floating
/// panel that opens over the window it customizes.
@MainActor
@Suite(.serialized)
struct AppearanceStudioTests {
    /// The studio opens over the window, at the top trailing corner of its
    /// content (below the titlebar), and leaves the rest of the window
    /// visible as the preview.
    @Test func theStudioOpensAtTheTopTrailingCornerOfTheContent() {
        let content = CGRect(x: 100, y: 100, width: 1200, height: 800)
        let frame = AppearanceStudioPlacement.frame(content: content)
        let gap = AppearanceStudioPlacement.gap
        #expect(frame == CGRect(x: 1300 - gap - AppearanceStudioPlacement.width, y: 900 - gap - AppearanceStudioPlacement.preferredHeight,
                                width: AppearanceStudioPlacement.width, height: AppearanceStudioPlacement.preferredHeight))
        #expect(content.contains(frame))
    }

    /// A small window shrinks the studio to fit inside its content.
    @Test func aSmallWindowShrinksTheStudioToItsContent() {
        let content = CGRect(x: 0, y: 0, width: 300, height: 400)
        let frame = AppearanceStudioPlacement.frame(content: content)
        let gap = AppearanceStudioPlacement.gap
        #expect(frame == content.insetBy(dx: gap, dy: gap))
    }

    @Test func customizeAppearanceIsBoundAndOfferedInSettings() throws {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(services.registry.isBound("appearance.customize"))
        let descriptor = try #require(services.registry.descriptor(for: "appearance.customize"))
        #expect(descriptor.surfaces.contains(.palette) && descriptor.surfaces.contains(.menu))
        #expect(SettingsSchema.actions(in: .appearance).first == "appearance.customize")
        withExtendedLifetime(services) {}
    }

    /// Customize Appearance is a sidebar item users can add (it runs the
    /// same action); the default bottom band leaves it out (decision S11).
    @Test func theSidebarItemOpensTheStudioAndIsNotInTheDefaultBand() throws {
        #expect(SidebarBridge.builtInActions[.customize] == "appearance.customize")
        let bottom = try #require(SidebarLayoutDocument.defaults.section(SidebarLayoutDocument.bottomSectionID))
        #expect(!bottom.items.contains { $0.ref == .builtIn(.customize) })
        #expect(SidebarBuiltIn.allCases.contains(.customize))
        #expect(SidebarBuiltIn.allCases.allSatisfy { SidebarBridge.builtInActions[$0] != nil })
    }
}
