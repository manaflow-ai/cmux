import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-07: "imagine the gradients are just, like, based off of placement, and they're not, like, just static.
/// They're, like, dynamic." Under the gradient palette a group draws the gradient's color at its place among the
/// colored groups; its stored color is kept, a custom color a person picked keeps its own, and no color stays glass.
@MainActor @Suite(.serialized, .closesItsWindows) struct GroupGradientPlacementTests {
    static func group(_ id: String, _ tint: GroupTint) -> SidebarGroup {
        var group = SidebarGroup(id: GroupID(id), name: id, workspaces: [SidebarWorkspace(id: WorkspaceID("\(id)-1"), title: id)])
        group.tint = tint
        return group
    }

    static let groups = [
        group("a", .palette(.purple)), group("mine", .custom(ThemeRGB(hex: 0x336699))), group("b", .palette(.cyan)),
        group("plain", .none), group("c", .palette(.red)),
    ]

    @Test func placedGroupsSpreadOverTheGradientInListOrder() {
        let tints = SidebarGroup.drawnTints(Self.groups, palette: .gradient, gradient: .sunset)
        #expect(tints[GroupID("a")] == SidebarGroup.gradientTint(.sunset, at: 0))
        #expect(tints[GroupID("b")] == SidebarGroup.gradientTint(.sunset, at: 0.5))
        #expect(tints[GroupID("c")] == SidebarGroup.gradientTint(.sunset, at: 1))
        #expect(tints[GroupID("mine")] == nil, "a picked custom color keeps its own")
        #expect(tints[GroupID("plain")] == nil, "no color stays glass")
    }

    /// A group that moves takes the color of its new place: the colors follow the order, not the group.
    @Test func aGroupThatMovesRecolors() {
        let moved = [Self.groups[4]] + Self.groups.dropLast()
        let tints = SidebarGroup.drawnTints(moved, palette: .gradient, gradient: .sunset)
        #expect(tints[GroupID("c")] == SidebarGroup.gradientTint(.sunset, at: 0))
        #expect(tints[GroupID("b")] == SidebarGroup.gradientTint(.sunset, at: 1))
    }

    /// Under the pictorial palette the picture's bands stand in for the gradient, top group from the top band; before
    /// the picture is sampled, nothing is placed (the groups draw the wallpaper palette).
    @Test func pictorialPlacesGroupsDownThePicture() {
        let bands = [WallpaperTint(red: 0.8, green: 0.2, blue: 0.1), WallpaperTint(red: 0.1, green: 0.6, blue: 0.3),
                     WallpaperTint(red: 0.1, green: 0.2, blue: 0.8)]
        let tints = SidebarGroup.drawnTints(Self.groups, palette: .pictorial, gradient: .sunset, wallpaper: bands)
        #expect(tints[GroupID("a")] == SidebarGroup.storedForm(GroupColor.pictorialRGB(bands, at: 0)))
        #expect(tints[GroupID("c")] == SidebarGroup.storedForm(GroupColor.pictorialRGB(bands, at: 1)))
        #expect(tints[GroupID("mine")] == nil && tints[GroupID("plain")] == nil)
        #expect(SidebarGroup.drawnTints(Self.groups, palette: .pictorial, gradient: .sunset).isEmpty)
    }

    @Test(arguments: GroupPalette.allCases.filter { $0 != .gradient && $0 != .pictorial })
    func anyOtherPaletteDrawsEachGroupsOwnTint(_ palette: GroupPalette) {
        #expect(SidebarGroup.drawnTints(Self.groups, palette: palette, gradient: .sunset).isEmpty)
    }

    /// The list draws the placed colors on headers and lines, and its groups keep their stored tokens.
    @Test func theListDrawsPlacesAndKeepsStoredColors() throws {
        let saved = DesignSettings.shared.sidebarSections
        defer { DesignSettings.shared.sidebarSections = saved }
        DesignSettings.shared.sidebarSections.groupPalette = .gradient
        DesignSettings.shared.sidebarSections.groupGradient = .aurora
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: Self.groups.map { .group($0) })],
                                 activeWorkspaceID: nil)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = sidebar
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        let list = sidebar.list
        #expect(list.drawnTints[GroupID("a")] == SidebarGroup.gradientTint(.aurora, at: 0))
        #expect(list.drawnTints[GroupID("c")] == SidebarGroup.gradientTint(.aurora, at: 1))
        #expect(list.lineColors[GroupID("b")]?.tint == SidebarGroup.gradientTint(.aurora, at: 0.5), "the line follows its place")
        #expect(list.groups[GroupID("b")]?.tint == .palette(.cyan), "the stored color is kept")
        #expect(list.lineColors[GroupID("mine")]?.tint == .custom(ThemeRGB(hex: 0x336699)))
    }
}
