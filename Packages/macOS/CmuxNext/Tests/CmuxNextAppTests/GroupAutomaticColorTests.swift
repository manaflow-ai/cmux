import AppKit
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

    /// Router review F3: every path that makes a group takes the palette's color, not only New Group. Dropping a row
    /// onto another groups them in the palette's next color, and under glass in none.
    @Test(arguments: [GroupPalette.vibrant, .glass])
    func droppingARowOntoAnotherGroupsThemInThePalettesNextColor(_ palette: GroupPalette) throws {
        let saved = DesignSettings.shared.sidebarSections.groupPalette
        DesignSettings.shared.sidebarSections.groupPalette = palette
        defer { DesignSettings.shared.sidebarSections.groupPalette = saved }
        _ = NSApplication.shared
        let a = WorkspaceID("ws-a"), b = WorkspaceID("ws-b")
        var purple = CmuxNextSidebar.SidebarGroup(id: GroupID("grp_purple"), name: "Purple", workspaces: [])
        purple.tint = .palette(.purple)
        let model = SidebarModel(sections: [
            CmuxNextSidebar.SidebarSection(kind: .pinned, nodes: [.group(purple), .workspace(SidebarWorkspace(id: a, title: "a")),
                                                                  .workspace(SidebarWorkspace(id: b, title: "b"))]),
        ], activeWorkspaceID: a)
        var sent: [SidebarIntent] = []
        model.onIntent = { sent.append($0) }
        let sidebar = SidebarView(model: model, design: DesignSettings())
        SidebarGroupDrop.group(sidebar.list, [b], onto: a, origin: nil)
        let color = try #require(sent.lazy.compactMap { intent -> GroupTint? in
            if case let .createGroup(_, _, color, _, _, _, _) = intent { color } else { nil }
        }.first)
        #expect(color == (palette == .glass ? GroupTint.none : .palette(.orange)), "the drop made a group in \(color)")
    }
}
