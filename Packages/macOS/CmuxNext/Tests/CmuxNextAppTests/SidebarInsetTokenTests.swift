import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar's row inset reads its two inputs (`SidebarDensityTokens.horizontalInset`), not the whole token set:
/// it must stay the inset `SidebarRowTokens` gives at every density.
@MainActor @Suite(.serialized) struct SidebarInsetTokenTests {
    @Test(arguments: SidebarDensity.allCases)
    func theRowInsetIsTheTokensInset(density: SidebarDensity) {
        let before = DesignSettings.shared.sidebarSections.density
        defer { DesignSettings.shared.sidebarSections.density = before }
        DesignSettings.shared.sidebarSections.density = density
        #expect(SidebarDensityTokens.horizontalInset == SidebarRowTokens.current.horizontalInset, "\(density)")
    }
}
