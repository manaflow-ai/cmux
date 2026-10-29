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

    /// A themed menu's rows: every one a native `NSMenuItem` AppKit draws (no custom row view,
    /// NativeContextMenuTests), each image in the grid's square icon box, so AppKit's image column
    /// is the grid's and every row's text starts on one column. Returns the menu's columns.
    private static func expectOnGrid(_ menu: NSMenu, _ name: String) -> (icon: CGFloat, text: CGFloat)? {
        let box = NSSize(width: MenuMetrics.iconSize, height: MenuMetrics.iconSize)
        for item in rows(menu) where !item.isSeparatorItem && !(item.view is MenuIdentityHeaderView) {
            #expect(item.view == nil, "\(name): \(item.title) has its own row view, off AppKit's grid")
            if let image = item.image {
                #expect(image.size == box, "\(name): \(item.title)'s icon is \(image.size), not the grid's box")
            }
        }
        let iconColumn = menu.items.contains { $0.image != nil }
        let stateColumn = menu.items.contains { $0.state != .off }
        guard menu.items.contains(where: { !$0.isSeparatorItem && $0.view == nil }) else { return nil }
        return (MenuMetrics.iconX(stateColumn: stateColumn), MenuMetrics.textX(iconColumn: iconColumn, stateColumn: stateColumn))
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
    /// dropdown/pop i think is similar"): the current profile's avatar is larger than the symbols, so
    /// AppKit's image column, and every row's text, sat right of the other menus'. Themed, the
    /// avatar and the symbols share the grid's icon box: one text column, the grid's.
    @Test func theProfileMenuSharesOneTextColumn() throws {
        let services = Self.services()
        let avatar = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.systemGray.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        let menu = ProfileMenuBuilder(registry: services.registry).make(profile: ProfileMenuProfile(name: "Default"), avatar: avatar)
            .themeRows(in: ThemeScope(level: .room))
        let columns = try #require(Self.expectOnGrid(menu, "profile"))
        #expect(columns.text == MenuMetrics.textX(iconColumn: true))
        let widths = Set(Self.rows(menu).compactMap { $0.image?.size.width })
        #expect(widths == [MenuMetrics.iconSize], "the profile menu's icons are \(widths.sorted()) wide")
    }

    /// The footer's profile control shows the App's menu themed: native rows on the grid.
    @Test func theSidebarShowsTheProfileMenuThemed() async throws {
        let h = try await SidebarBandHideTests().make()
        defer { h.tearDown() }
        let menu = NSMenu()
        let current = menu.addItem(withTitle: "Default", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        current.image = NSImage(size: NSSize(width: 18, height: 18))
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(NSText.copy(_:)), keyEquivalent: ",")
        settings.image = NSImage.menuSymbol("gearshape")
        h.sidebar.profileMenuProvider = { menu }
        var shown: NSMenu?
        h.sidebar.footerBand.profileMenuPresenter = { menu, _ in shown = menu }
        #expect(h.sidebar.footerBand.showProfileMenu(from: nil))
        let themed = try #require(shown)
        #expect(themed.appearance != nil, "the profile menu opens in the sidebar's light or dark")
        _ = Self.expectOnGrid(themed, "sidebar profile")
    }

    /// An ordinary row's icon goes in the grid's box, its shape kept: a large or wide image is
    /// scaled down, a small one is centered, a template stays a template, and theming twice
    /// changes nothing.
    @Test func anOrdinaryRowsIconFitsTheGridsBox() {
        _ = NSApplication.shared
        let side = MenuMetrics.iconSize
        let wide = NSImage(size: NSSize(width: 28, height: 14))
        wide.isTemplate = true
        wide.accessibilityDescription = "Wide"
        let menu = NSMenu()
        let row = menu.addItem(withTitle: "Wide", action: nil, keyEquivalent: "")
        row.image = wide
        let plain = menu.addItem(withTitle: "Plain", action: nil, keyEquivalent: "")
        menu.themeRows(in: ThemeScope(level: .room))
        let fitted = row.image
        #expect(fitted?.size == NSSize(width: side, height: side))
        #expect(fitted?.isTemplate == true)
        #expect(fitted?.accessibilityDescription == "Wide")
        #expect(plain.image == nil, "a row with no icon gets none")
        menu.themeRows(in: ThemeScope(level: .room))
        #expect(row.image === fitted, "theming again keeps the fitted icon")
    }

    /// Rows a menu adds while open (a search's results, `themeAddedRows()`) get the same box as
    /// the rows it opened with, so filtering never changes an icon's size.
    @Test func rowsAddedWhileOpenFitTheGridsBoxToo() {
        _ = NSApplication.shared
        let box = NSSize(width: MenuMetrics.iconSize, height: MenuMetrics.iconSize)
        let menu = NSMenu()
        let first = menu.addItem(withTitle: "First", action: nil, keyEquivalent: "")
        first.image = NSImage(size: NSSize(width: 18, height: 18))
        menu.themeRows(in: ThemeScope(level: .room))
        let fitted = first.image
        let added = menu.addItem(withTitle: "Result", action: nil, keyEquivalent: "")
        added.image = NSImage(size: NSSize(width: 20, height: 16))
        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        more.submenu = NSMenu()
        let nested = more.submenu!.addItem(withTitle: "Nested", action: nil, keyEquivalent: "")
        nested.image = NSImage(size: NSSize(width: 9, height: 22))
        menu.addItem(more)
        menu.themeAddedRows()
        #expect(added.image?.size == box)
        #expect(nested.image?.size == box)
        #expect(first.image === fitted, "a row already fitted is left as it is")
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
