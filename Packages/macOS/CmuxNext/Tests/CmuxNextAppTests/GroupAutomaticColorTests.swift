import CmuxNextDesign
import CmuxTheme
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-06: "Oh yeah, and of course, like the automatic group colors." A new group takes the chosen palette's
/// next color; under glass, the default, it takes none (Leo 2026-10-31: "WHY DOES THIS HAVE A LINE AND COLOR").
@MainActor struct GroupAutomaticColorTests {
    static func sections(_ tints: [GroupTint]) -> [CmuxNextSidebar.SidebarSection] {
        let nodes: [SidebarNode] = tints.enumerated().map { index, tint in
            var group = CmuxNextSidebar.SidebarGroup(id: GroupID("grp_\(index)"), name: "Group \(index)", workspaces: [])
            group.tint = tint
            return .group(group)
        }
        return [CmuxNextSidebar.SidebarSection(kind: .pinned, nodes: nodes)]
    }

    @Test func underGlassANewGroupHasNoColor() {
        #expect(CmuxNextSidebar.SidebarGroup.newTint(in: Self.sections([]), palette: .glass) == .none)
        #expect(CmuxNextSidebar.SidebarGroup.newTint(in: Self.sections([.palette(.purple)]), palette: .glass) == .none)
    }

    @Test(arguments: [GroupPalette.theme, .wallpaper, .grayscale, .vibrant])
    func underAPaletteANewGroupTakesTheNextColorBesideTheOthers(_ palette: GroupPalette) {
        #expect(CmuxNextSidebar.SidebarGroup.newTint(in: Self.sections([]), palette: palette) == .palette(.purple))
        let existing: [GroupTint] = [.palette(.purple), .none, .custom(ThemeRGB(hex: 0x336699))]
        #expect(CmuxNextSidebar.SidebarGroup.newTint(in: Self.sections(existing), palette: palette) == .palette(.orange))
    }
}
