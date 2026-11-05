import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxTheme
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
        // An untinted group has no color of its own: no dot or swatch (its header keeps a neutral background).
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
    /// Leo 2026-11-02, on a group nobody colored whose header drew a solid bar in the theme's own color: "THE
    /// GROUP COLOUR SOMEHOW BEING THE THEME COLOUR???" / "IT'S USELESS". Lawrence 2026-11-05: "invariant: groups
    /// must always have a visible bg color". No color draws no color of its own: no theme-colored bar and no dot,
    /// but a neutral background (a step of the theme's text into the sidebar) that a person can see. The editor's
    /// "No color" dot clears the color instead of storing a grey band.
    @Test func noColorHeaderDrawsAVisibleNeutralBarAndNoColorDotClears() throws {
        #expect(GroupTint.palette(.blue).headerChip.fill.alpha == 1, "a picked color keeps its bar")

        let header = GroupHeaderRowView(key: .group(GroupID("grp_none")))
        header.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        let group = CmuxNextSidebar.SidebarGroup(id: GroupID("grp_none"), name: "cosmic-gray", custom: "none", workspaces: [])
        let row = SidebarRow(key: .group(group.id), y: 0, height: 24, section: .pinned, group: group.id, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil)
        header.configure(group, row: row, details: GroupHeaderDetails(background: .solid), animated: false)
        header.updateLayer()
        #expect(Self.alpha(header.pill.backgroundColor) == 1, "an uncolored header paints its solid neutral bar at rest")
        #expect(header.dot.isHidden, "an uncolored header shows no color dot")
        let tokens = ThemeScope.app.tokens
        let want = GroupBackground(tint: .none, strength: .band, glass: false, themed: false, tokens: tokens)
        let drawn = try #require(header.pill.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        let rgb = ThemeRGB(red: drawn.redComponent, green: drawn.greenComponent, blue: drawn.blueComponent)
        #expect(abs(rgb.red - want.shown.red) < 0.006 && abs(rgb.green - want.shown.green) < 0.006
            && abs(rgb.blue - want.shown.blue) < 0.006, "the bar is \(rgb), want the neutral \(want.shown)")
        #expect(rgb.contrast(with: tokens.sidebarBackground.withAlpha(1)) >= GroupBackground.minimumVisibleContrast - 0.01,
                "the neutral bar is not visible against the sidebar")
        #expect(!(abs(rgb.red - tokens.sidebarBackground.red) < 0.006 && abs(rgb.green - tokens.sidebarBackground.green) < 0.006
            && abs(rgb.blue - tokens.sidebarBackground.blue) < 0.006), "the bar is the theme's own background color")

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
