import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Every cmux NEXT menu sits on one row grid (Leo 2026-10-21: "idk if we generalized the left
/// alignment across all stuff yet", on Lawrence's screenshots of the sidebar group menu and the
/// pane [+] menu, whose highlights, separators and columns sat at different x). The grid is
/// schemas/menu-metrics/menu-metrics.json (`MenuMetrics`); scripts/cmux-next/check-menu-metrics.py
/// fails a menu that sets its own paddings. These measure the menus the app builds.
@MainActor
struct MenuGridTests {
    private static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    /// Every row of `menu` and its submenus.
    private static func rows(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(rows) ?? []) }
    }

    /// A themed menu's rows: each drawn by cmux on the grid, the text column shared by rows
    /// with and without an icon. Returns the columns it measured.
    private static func expectOnGrid(_ menu: NSMenu, _ name: String) -> (icon: CGFloat, text: CGFloat)? {
        var measured: (icon: CGFloat, text: CGFloat)?
        for item in rows(menu) where !item.isSeparatorItem && !item.isSectionHeader && !(item.view is MenuIdentityHeaderView) {
            guard item.view is ThemedMenuRowView else {
                if item.view == nil { Issue.record("\(name): \(item.title) is drawn by AppKit, off the menu grid") }
                continue
            }
            let columns = ThemedMenuRowView.columns(of: item)
            let iconColumn = item.menu?.items.contains { $0.image != nil } == true
            let stateColumn = item.menu?.items.contains { $0.state != .off } == true
            #expect(columns.icon == MenuMetrics.iconX(stateColumn: stateColumn), "\(name): \(item.title)'s icon at \(columns.icon)")
            #expect(columns.text == MenuMetrics.textX(iconColumn: iconColumn, stateColumn: stateColumn),
                    "\(name): \(item.title)'s text at \(columns.text)")
            if item.menu === menu { measured = columns }
        }
        return measured
    }

    /// The registry's menus, themed as every caller shows them: on the grid.
    @Test func everyContextMenuIsOnTheGrid() {
        let services = Self.services()
        var table: [String] = []
        for context in ActionMenuContext.allCases {
            let menu = services.registry.makeContextMenu(for: context).themeRows(in: ThemeScope(level: .room))
            guard !menu.items.isEmpty else { continue }
            if let columns = Self.expectOnGrid(menu, context.rawValue) {
                table.append("\(context.rawValue): icon x \(columns.icon), text x \(columns.text)")
            }
        }
        #expect(!table.isEmpty)
        print("menu-grid\n" + table.joined(separator: "\n"))
    }

    /// The pane's [+] menu, one of the two menus in Lawrence's screenshots.
    @Test func theNewTabMenuIsOnTheGrid() throws {
        let services = Self.services()
        let menu = services.registry.makeContextMenu(for: .newTab).themeRows(in: ThemeScope(level: .room))
        let columns = try #require(Self.expectOnGrid(menu, "new tab"))
        #expect(columns.icon == MenuMetrics.iconX && columns.text == MenuMetrics.textX(iconColumn: true), "\(columns)")
    }

    /// The sidebar group menu, the other one: its name field's box on the rows' highlight edge and
    /// its first swatch on their icon column.
    @Test func theGroupMenuHeaderIsOnTheGrid() throws {
        let services = Self.services()
        let group = GroupID("grid-g")
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
            .group(SidebarGroup(id: group, name: "cmux-next app", color: .blue, workspaces: [SidebarWorkspace(id: WorkspaceID("grid-in"), title: "web")])),
        ])])
        let menu = try #require(SidebarContextMenus.menu(for: .group(group), model: model, services: services, scope: ThemeScope(level: .room)))
        _ = Self.expectOnGrid(menu, "group")
        let header = try #require(menu.items.first?.view as? MenuIdentityHeaderView)
        header.frame.size.width = 280
        header.layoutSubtreeIfNeeded()
        if let field = header.field {
            #expect(field.frame.minX == MenuMetrics.highlightInset, "the name field's box at \(field.frame.minX)")
            #expect(header.bounds.width - field.frame.maxX == MenuMetrics.highlightInset)
        }
        let strip = try #require(header.strip)
        #expect(strip.frame.minX + MenuSwatchStrip.ringRoom == MenuMetrics.iconX, "the first swatch at \(strip.frame.minX + MenuSwatchStrip.ringRoom)")
    }

    /// The sidebar footer's profile menu (Leo 2026-10-21: "left alignment on the profile settings
    /// dropdown/pop i think is similar"): the current profile's avatar was the menu's one image, and
    /// AppKit pushed that row's name right of every other row's text. Themed, the avatar sits on the
    /// icon column and every row's text on one column.
    @Test func theProfileMenuSharesOneTextColumn() throws {
        let services = Self.services()
        let avatar = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.systemGray.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        let menu = ProfileMenuBuilder(registry: services.registry).make(profile: ProfileMenuProfile(name: "Default"), avatar: avatar)
            .themeRows(in: ThemeScope(level: .room))
        let columns = try #require(Self.expectOnGrid(menu, "profile"))
        #expect(columns.text == MenuMetrics.textX(iconColumn: true))
        let texts = Set(menu.items.filter { $0.view is ThemedMenuRowView }.map { ThemedMenuRowView.columns(of: $0).text })
        #expect(texts == [MenuMetrics.textX(iconColumn: true)], "the profile menu's rows start their text at \(texts.sorted())")
    }

    /// The footer's profile control shows the App's menu themed, not as AppKit draws it.
    @Test func theSidebarShowsTheProfileMenuThemed() async throws {
        let h = try await SidebarBandHideTests().make()
        defer { h.tearDown() }
        let menu = NSMenu()
        let current = menu.addItem(withTitle: "Default", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        current.image = NSImage(size: NSSize(width: 12, height: 12))
        menu.addItem(withTitle: "Settings…", action: #selector(NSText.copy(_:)), keyEquivalent: ",")
        h.sidebar.profileMenuProvider = { menu }
        var shown: NSMenu?
        h.sidebar.footerBand.profileMenuPresenter = { menu, _ in shown = menu }
        #expect(h.sidebar.footerBand.showProfileMenu(from: nil))
        let rows = try #require(shown).items
        #expect(rows.allSatisfy { $0.view is ThemedMenuRowView }, "the profile menu is drawn by AppKit")
        #expect(Set(rows.map { ThemedMenuRowView.columns(of: $0).text }) == [MenuMetrics.textX(iconColumn: true)])
    }

    /// The grid's own sense: a menu's columns read left to right inside its highlight.
    @Test func theGridReadsLeftToRight() {
        #expect(MenuMetrics.highlightInset < MenuMetrics.stateX && MenuMetrics.stateX < MenuMetrics.stateIconX)
        #expect(MenuMetrics.textX(iconColumn: false) == MenuMetrics.iconX)
        #expect(MenuMetrics.textX(iconColumn: true) == MenuMetrics.iconX + MenuMetrics.iconSize + MenuMetrics.iconGap)
        #expect(MenuMetrics.textX(iconColumn: true, stateColumn: true) == MenuMetrics.stateIconX + MenuMetrics.iconSize + MenuMetrics.iconGap)
        // Native: a row's content starts where AppKit's separators start.
        #expect(MenuMetrics.separatorInset == MenuMetrics.iconX)
    }
}
