import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Testing

/// Leo 2026-10-31, on a tab group nobody colored that drew a brown dot and an orange underline: "WHY DOES
/// THIS HAVE A LINE AND COLOR??????" / "WHERE IS ORANGE COMING FROM????? AN ORANGE DOT????". A group
/// shows a color only when a person picked one: a group with no stored color draws no dot, no
/// underline or wash on its tabs, and an untinted sidebar header. A picked color draws as before.
/// (This replaces 2026-10-20's hashed palette color for groups with no stored color.)
@MainActor
struct GroupNoChosenColorTests {
    private static func sidebarGroup(_ id: String, color: String?) -> CmuxNextSidebar.SidebarGroup? {
        let model = WorkspaceGroupModel(WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: id), name: id, color: color))
        let sections = SidebarMapping.shared.sections([CmuxNextDaemon.SidebarSection(group: model, workspaces: [])],
                                                      machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
        for node in sections.flatMap(\.nodes) {
            if case let .group(group) = node { return group }
        }
        return nil
    }

    private static func tabGroup(color: String?) -> TabGroupItem {
        TabItemMapping.shared.groupItem(TabGroupModel(TabGroupSnapshot(id: "tgrp_1", name: "", color: color)), isSaved: false)
    }

    private static func alpha(_ color: CGColor?) -> CGFloat { color.flatMap(NSColor.init(cgColor:))?.alphaComponent ?? 0 }

    @Test func sidebarGroupWithNoColorHasNoTint() throws {
        let ids = ["grp_2916936ea9914e6ca942a58b5f96a2e7", "grp_8cd4b80f3586401c86f6b643dc46342e", "coordinators"]
        for id in ids {
            let group = try #require(Self.sidebarGroup(id, color: nil))
            #expect(group.tint == .none, "\(id): no stored color is no color, never a picked one")
        }
        // An untinted header: no dot, band or members' line (`GroupTint.none` draws in the sidebar's own colors).
        #expect(GroupTint.none.headerFill.alphaComponent == 0)
        #expect(GroupTint.none.chipFill.alphaComponent == 0)
    }

    @Test func tabGroupWithNoColorDrawsNoDotAndNoUnderline() {
        let item = Self.tabGroup(color: nil)
        #expect(item.tint == .none)
        let chip = TabGroupChipCell(group: item, memberCount: 1)
        #expect(Self.alpha(chip.pill.backgroundColor) == 0, "no dot")
        let band = TabGroupBandCell(color: item.tint)
        #expect(Self.alpha(band.lineLayer.backgroundColor) == 0, "no underline")
        // A faint neutral wash, no hue (Leo 2026-11-05: "a grouped up thing"): the theme's sidebarStep, under the hover.
        let wash = Self.alpha(band.washLayer.backgroundColor)
        #expect(wash > 0 && wash < 0.06, "a faint neutral wash, not \(wash)")
        #expect(band.washLayer.backgroundColor?.components == band.themeScope.perform { Palette.sidebarStep.cgColor }.components)
        // The daemon's explicit `none` reads the same.
        #expect(Self.tabGroup(color: "none").tint == .none)
    }

    @Test func pickedColorsAreKept() throws {
        #expect(try #require(Self.sidebarGroup("grp_a", color: "grey")).tint == .palette(.grey))
        #expect(try #require(Self.sidebarGroup("grp_a", color: "green")).tint == .palette(.green))
        #expect(try #require(Self.sidebarGroup("grp_a", color: "#336699")).tint == GroupTint(wire: "#336699"))
        #expect(try #require(Self.sidebarGroup("grp_a", color: "none")).tint == .none)
        #expect(Self.tabGroup(color: "red").tint == .palette(.red))
        let band = TabGroupBandCell(color: .palette(.red))
        #expect(Self.alpha(band.lineLayer.backgroundColor) > 0, "a picked color keeps its underline")
    }
    /// Leo 2026-11-02, on a group nobody colored whose header drew a solid bar in the theme's own color: "THE
    /// GROUP COLOUR SOMEHOW BEING THE THEME COLOUR???" / "IT'S USELESS". No color draws no bar, chip or wash
    /// (an opaque sidebarBackground bar was the theme color over the translucent sidebar), and the editor's
    /// "No color" dot clears the color instead of storing a grey band.
    @Test func noColorHeaderDrawsNoBarAndNoColorDotClears() throws {
        #expect(GroupTint.none.headerChip.fill.alpha == 0, "no bar")
        #expect(GroupTint.none.headerChip(themed: true).fill.alpha == 0, "no themed bar")
        #expect(GroupTint.none.headerChip(themed: false).fill.alpha == 0)
        #expect(GroupTint.none.headerWash(themed: true).alpha == 0, "no wash")
        #expect(GroupTint.none.headerWash(themed: false).alpha == 0)
        #expect(GroupTint.palette(.blue).headerChip.fill.alpha == 1, "a picked color keeps its bar")

        let header = GroupHeaderRowView(key: .group(GroupID("grp_none")))
        header.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        let group = CmuxNextSidebar.SidebarGroup(id: GroupID("grp_none"), name: "cosmic-gray", custom: "none", workspaces: [])
        let row = SidebarRow(key: .group(group.id), y: 0, height: 24, section: .pinned, group: group.id, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil)
        header.configure(group, row: row, animated: false)
        header.updateLayer()
        #expect(Self.alpha(header.pill.backgroundColor) == 0, "an uncolored header paints no bar at rest")

        let editor = SidebarGroupEditorPanel()
        var picked: GroupTint?
        editor.onColor = { picked = $0 }
        editor.pick(.grey)
        #expect(picked == GroupTint.none, "the No color dot clears the color")
        #expect(try #require(editor.swatches.first { $0.color == .grey }).isChosen)
        editor.pick(.green)
        #expect(picked == .palette(.green))
    }
}
