import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-22: "need to be able to remove all workspace colors", over a group's menu
/// whose swatches had no way back to no color. A workspace and a group each get a No Color swatch
/// first in their menu's swatches; a group can store no color (`none`) and then draws no dot, band
/// or line; Remove All Workspace Colors clears every one at once; and `sidebar.showColors` turns
/// every workspace and group color off in the sidebar without changing what is stored.
@MainActor
struct WorkspaceNoColorTests {
    private static let workspaceTarget = ActionTargetRef(kind: .workspace, id: "ws")
    private static let groupTarget = ActionTargetRef(kind: .workspaceGroup, id: "g")

    /// Every row of `menu` and its submenus.
    private static func rows(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(rows) ?? []) }
    }

    private static func workspaceMenu() -> (ActionRegistry, NSMenu) {
        let registry = ActionRegistry.standard()
        registry.bind("renameWorkspace", invoke: { _ in })
        registry.bind("palette.workspaceColor", invoke: { _ in })
        registry.bind("palette.resetWorkspaceColor", invoke: { _ in })
        registry.bind("workspace.removeAllColors", invoke: { _ in })
        return (registry, registry.makeContextMenu(for: .workspaceRow, target: workspaceTarget))
    }

    @Test func aWorkspaceMenuStartsItsSwatchesWithNoColor() throws {
        let (registry, menu) = Self.workspaceMenu()
        MenuIdentityHeader.install(in: menu, registry: registry, target: Self.workspaceTarget, name: "api", rename: "renameWorkspace")
        let strip = try #require((menu.items.first?.view as? MenuIdentityHeaderView)?.strip)
        let actions = try #require(strip.accessibilityCustomActions())
        #expect(actions.first?.name == "No Color",
                "the first swatch is No Color")
        // The swatch is the reset: it is not also a row further down.
        #expect(!Self.rows(menu).contains { ActionRegistry.menuRun(of: $0)?.id == "palette.resetWorkspaceColor" })
    }

    @Test func aGroupMenuStartsItsSwatchesWithNoColor() throws {
        let registry = ActionRegistry.standard()
        let menu = registry.makeContextMenu(for: .workspaceGroup, target: Self.groupTarget)
        MenuIdentityHeader.install(in: menu, registry: registry, target: Self.groupTarget, name: "api", rename: "workspaceGroup.rename",
                                   current: .blue)
        let strip = try #require((menu.items.first?.view as? MenuIdentityHeaderView)?.strip)
        let first = try #require(strip.accessibilityCustomActions()?.first)
        #expect(first.name == "No Color")
    }

    @Test func aGroupCanStoreNoColor() throws {
        #expect(GroupTint(wire: "none")?.wire == "none", "none is a group color the daemon stores")
        let model = WorkspaceGroupModel(WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: "grp_a"), name: "a", color: "none"))
        let sections = SidebarMapping.shared.sections([CmuxNextDaemon.SidebarSection(group: model, workspaces: [])],
                                                      machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
        let group = try #require(sections.flatMap(\.nodes).compactMap { node -> CmuxNextSidebar.SidebarGroup? in
            if case let .group(group) = node { return group }
            return nil
        }.first)
        #expect(group.tint.wire == "none", "a group stored with no color does not draw a picked palette color")
    }

    /// Leo 2026-10-23 trimmed the workspace row menu: Remove All Workspace Colors is on a group's
    /// menu and in the palette, not on every row.
    @Test func removeAllWorkspaceColorsIsOnTheGroupMenuAndInThePalette() throws {
        let catalog = ContextMenuCatalog.shared
        #expect(catalog.referencedIDs(catalog.entries(for: .workspaceGroup)).contains("workspace.removeAllColors"))
        #expect(!catalog.referencedIDs(catalog.entries(for: .workspaceRow)).contains("workspace.removeAllColors"))
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: "workspace.removeAllColors"))
        #expect(descriptor.surfaces.contains(.palette))
    }

    /// Remove All Workspace Colors sets every listed group that draws a color to no color, once each.
    @Test func removeAllFindsEveryColoredGroupOnce() {
        var plain = CmuxNextSidebar.SidebarGroup(id: GroupID("plain"), name: "plain", workspaces: [])
        plain.tint = GroupTint.none
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .group(CmuxNextSidebar.SidebarGroup(id: GroupID("red"), name: "red", color: .red, workspaces: [])),
            .group(CmuxNextSidebar.SidebarGroup(id: GroupID("grey"), name: "grey", color: .grey, workspaces: [])),
            .group(CmuxNextSidebar.SidebarGroup(id: GroupID("custom"), name: "custom", custom: "#336699", workspaces: [])),
            .group(plain),
        ])]
        let model = SidebarModel(sections: sections)
        #expect(model.coloredGroups == [GroupID("red"), GroupID("grey"), GroupID("custom")])
        for id in model.coloredGroups { model.send(.setGroupColor(id, GroupTint.none)) }
        #expect(model.coloredGroups.isEmpty, "after the edits no listed group draws a color")
    }

    @Test func theShowColorsSettingIsListedAndOnByDefault() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["sidebar", "showColors"]))
        #expect(row.defaultValue == .bool(true))
    }

    /// `sidebar.showColors: false` draws no workspace's color: a swatch goes, a symbol and an
    /// emoji keep their glyph without the color.
    @Test func withColorsOffNoRowDrawsAColor() throws {
        let root: CmuxNextSettings.JSONValue = .object(["sidebar": .object(["showColors": .bool(false)])])
        let preferences = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).sidebarSections
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("a"), title: "a", icon: .swatch(.red))),
            .workspace(SidebarWorkspace(id: WorkspaceID("b"), title: "b", icon: .symbol("star", tint: .green))),
            .workspace(SidebarWorkspace(id: WorkspaceID("c"), title: "c", icon: .emoji("🚀", chip: .purple))),
        ])]
        let model = SidebarModel(sections: sections)
        model.applyListPreferences(preferences)
        let layout = SidebarLayout.make(sections: sections, metrics: .standard, options: model.listOptions())
        var icons: [String: WorkspaceIcon?] = [:]
        for row in layout.rows {
            if case let .workspace(id) = row.key { icons[id.rawValue] = row.content?.icon }
        }
        #expect(icons["a"] == .some(nil))
        #expect(icons["b"] == .some(.symbol("star", tint: nil)))
        #expect(icons["c"] == .some(.emoji("🚀", chip: nil)))
    }
}
