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
        #expect(Self.alpha(band.washLayer.backgroundColor) == 0, "no wash")
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
}
