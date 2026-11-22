import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar's workspace and group menus as the app builds them (`SidebarContextMenus`), not
/// their parts alone: Chrome's tab-group menu look (Leo and Lawrence 2026-10-20, "this got
/// regressed again"). The name and colors open the menu in place of Rename… and a color row,
/// every other row is a standard macOS menu row with an icon (Lawrence 2026-10-23: "we don't want
/// ANYTHING custom besides the icons"), and nothing is left in a nested More of More.
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
            #expect(item.view == nil, "\(name): \(item.title) is custom-drawn, not a standard macOS row")
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

    /// More holds rows and at most one level of submenus: no More inside More.
    @Test func moreIsNotNested() throws {
        let menu = try Self.menu(.workspaces([Self.workspace]))
        let more = try #require(menu.items.first { $0.title == MenuFolder.more.title }?.submenu)
        #expect(!more.items.contains { $0.title == MenuFolder.more.title })
        // Short folders are sections; a folder that grows beyond the shared inline limit remains
        // one submenu so the menu still fits. The submenu must never contain another More.
        #expect(!more.items.contains { $0.title == MenuFolder.more.title && $0.submenu != nil })
        for item in more.items where item.submenu != nil {
            #expect(item.title != MenuFolder.more.title)
        }
    }
}
