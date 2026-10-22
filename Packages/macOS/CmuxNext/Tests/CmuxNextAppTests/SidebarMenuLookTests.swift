import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar's workspace and group menus as the app builds them (`SidebarContextMenus`), not
/// their parts alone: Chrome's tab-group menu look (Leo and Lawrence 2026-10-20, "this got
/// regressed again"). The name and colors open the menu in place of Rename… and a color row,
/// every row is cmux-drawn (a wash of the theme's accent on the glass, never the system blue)
/// and has an icon, and nothing is left in a nested More of More.
@MainActor
struct SidebarMenuLookTests {
    private static let workspace = WorkspaceID("look-ws"), group = GroupID("look-g")

    private static func menu(_ target: SidebarContextTarget) throws -> NSMenu {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let nodes: [SidebarNode] = [
            .group(SidebarGroup(id: group, name: "Frontend", color: .blue, workspaces: [SidebarWorkspace(id: WorkspaceID("look-in"), title: "web")])),
            .workspace(SidebarWorkspace(id: workspace, title: "api")),
        ]
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: workspace)
        return try #require(SidebarContextMenus.menu(for: target, model: model, services: services, scope: ThemeScope(level: .room)))
    }

    /// The look every sidebar workspace or group menu keeps.
    private static func expectChromeLook(_ menu: NSMenu, _ name: String) throws {
        let header = try #require(menu.items.first?.view as? MenuIdentityHeaderView, "\(name): the menu opens with its name and colors")
        #expect(header.field != nil || header.strip != nil)
        #expect(menu.items.count > 1 && menu.items[1].isSeparatorItem, "\(name): a separator under the header")
        for item in menu.items.dropFirst() where !item.isSeparatorItem {
            #expect(item.view is ThemedMenuRowView, "\(name): \(item.title) is drawn by AppKit (system blue highlight)")
            #expect(item.image != nil, "\(name): \(item.title) has no icon")
            // A rename that can't run here (the group's needs a daemon) keeps its disabled row; the header is the swatches.
            if header.field != nil { #expect(!item.title.hasPrefix("Rename"), "\(name): Rename… is the header's field") }
            let colors = item.submenu?.items.compactMap(MenuIdentityHeader.color(of:)) ?? []
            #expect(colors.count < 2, "\(name): \(item.title) is a color row; the colors are the header's swatches")
        }
    }

    @Test func theWorkspaceMenuLooksLikeChromes() throws {
        let menu = try Self.menu(.workspaces([Self.workspace]))
        try Self.expectChromeLook(menu, "workspace")
        let header = try #require(menu.items.first?.view as? MenuIdentityHeaderView)
        if let field = header.field { #expect(field.stringValue == "api") }
    }

    @Test func theGroupMenuLooksLikeChromes() throws {
        let menu = try Self.menu(.group(Self.group))
        try Self.expectChromeLook(menu, "group")
        let header = try #require(menu.items.first?.view as? MenuIdentityHeaderView)
        #expect(header.strip != nil, "group: the colors are swatches")
    }

    /// A colored workspace's menu offers Reset Workspace Color just under the swatches; an
    /// uncolored one's leaves it out, More included.
    @Test func resetColorSitsUnderTheSwatchesOnlyForAColoredWorkspace() throws {
        let ids = { (entries: [ContextMenuEntry]) in ContextMenuCatalog.shared.referencedIDs(entries) }
        for selection in [false, true] {
            #expect(ids(SidebarContextMenus.workspaceEntries(selection: selection, highlighted: false, colored: true)).contains("palette.resetWorkspaceColor"))
            #expect(!ids(SidebarContextMenus.workspaceEntries(selection: selection, highlighted: false, colored: false)).contains("palette.resetWorkspaceColor"))
        }
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let target = ActionTargetRef(kind: .workspace, id: Self.workspace.rawValue)
        let menu = services.registry.makeContextMenu(for: .workspaceRow, target: target,
                                                     entries: SidebarContextMenus.workspaceEntries(selection: false, highlighted: false, colored: true))
        MenuIdentityHeader.install(in: menu, registry: services.registry, target: target, name: "api", rename: "renameWorkspace")
        SidebarContextMenus.liftResetColor(in: menu)
        #expect(menu.items.first?.view is MenuIdentityHeaderView)
        #expect(menu.items.count > 2 && ActionRegistry.menuRun(of: menu.items[2])?.id == "palette.resetWorkspaceColor")
        #expect(menu.items.filter { !$0.isSeparatorItem }.count <= SidebarContextMenus.topLevelLimit)
        let more = try #require(menu.items.first { $0.title == MenuFolder.more.title }?.submenu)
        #expect(!more.items.contains { ActionRegistry.menuRun(of: $0)?.id == "palette.resetWorkspaceColor" })
        for (index, item) in more.items.enumerated() where item.isSeparatorItem {
            #expect(index > 0 && index < more.items.count - 1 && !more.items[index + 1].isSeparatorItem, "More keeps no stray separator")
        }
    }

    /// More holds rows and at most one level of submenus: no More inside More.
    @Test func moreIsNotNested() throws {
        let menu = try Self.menu(.workspaces([Self.workspace]))
        let more = try #require(menu.items.first { $0.title == MenuFolder.more.title }?.submenu)
        #expect(!more.items.contains { $0.title == MenuFolder.more.title })
        // New sits at `ContextMenuEssentials.inlineFolderLimit` rows: a ninth New row would fold it back into a submenu.
        for folder in [MenuFolder.new, .appearance, .copy, .tools, .close] {
            #expect(!more.items.contains { $0.title == folder.title && $0.submenu != nil }, "More › \(folder.title) should be a section of More")
        }
    }
}
