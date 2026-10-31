import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import Testing

/// One text column in a native menu (design/grid.md 5.3: "a row without an icon still starts its
/// text on `text`"). AppKit indents a row's title by its own image, so a menu where some rows have
/// an image and others do not starts its text at two x's (Leo 2026-10-22, on the sidebar profile
/// menu: "left alignment on the profile settings dropdown/pop i think is similar"; the email header
/// and Sign Out sat left of every row with an icon). The native form of the rule: within one menu,
/// every text row has an image (the grid's box) or none does.
@MainActor
struct ProfileMenuColumnTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    /// A menu's own text rows: every row AppKit draws a title for (not separators, not custom views).
    private static func textRows(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSeparatorItem && $0.view == nil }
    }

    /// The rows of `menu` and of its submenus, each menu judged on its own, whose title starts on a
    /// different x than the menu's other rows: the rows without an image in a menu where some
    /// row has one.
    static func offColumn(_ menu: NSMenu, _ name: String) -> [String] {
        let rows = textRows(menu)
        let withImage = rows.filter { $0.image != nil }
        var off: [String] = []
        if !withImage.isEmpty, withImage.count != rows.count {
            off += rows.filter { $0.image == nil }.map { "\(name) > \($0.title)" }
        }
        for row in rows {
            if let submenu = row.submenu { off += offColumn(submenu, "\(name) > \(row.title)") }
        }
        return off
    }

    /// The footer's profile menu as the app shows it: the built rows, the account rows, themed.
    static func profileMenu(signedIn: Bool, services: AppServices) -> NSMenu {
        let avatar = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            NSColor.systemGray.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        let builder = ProfileMenuBuilder(registry: services.registry)
        let menu = builder.make(profile: ProfileMenuProfile(name: "Default"), avatar: avatar, chiefPetShown: true)
        builder.addAccountRows(to: menu, who: signedIn ? ["Sample User", "user@example.com"] : nil, team: signedIn ? "Sample Team" : nil)
        return menu.themeRows(in: ThemeScope(level: .room))
    }

    @Test(arguments: [true, false])
    func everyProfileMenuRowStartsItsTextOnOneColumn(signedIn: Bool) {
        let menu = Self.profileMenu(signedIn: signedIn, services: Self.services())
        let off = Self.offColumn(menu, "profile")
        #expect(off.isEmpty, "rows whose text starts left of the menu's text column: \(off)")
        let box = NSSize(width: MenuMetrics.iconSize, height: MenuMetrics.iconSize)
        let sizes = Set(Self.textRows(menu).compactMap { $0.image?.size }.map { "\($0.width)x\($0.height)" })
        #expect(sizes == ["\(box.width)x\(box.height)"], "the profile menu's icons are \(sizes.sorted())")
    }

    /// A profile with no avatar still starts its name on the text column.
    @Test func aProfileWithoutAnAvatarStaysOnTheColumn() {
        let menu = ProfileMenuBuilder(registry: Self.services().registry).make(profile: ProfileMenuProfile(name: "Work"), avatar: nil)
        #expect(Self.offColumn(menu, "profile").isEmpty)
    }

    /// The registry's context menus, themed as every caller shows them. Printed for the record;
    /// the profile menu is the one this test holds to the rule.
    @Test func everyContextMenusTextColumns() {
        let services = Self.services()
        var table: [String] = []
        for context in ActionMenuContext.allCases {
            let menu = services.registry.makeContextMenu(for: context).themeRows(in: ThemeScope(level: .room))
            let off = Self.offColumn(menu, context.rawValue)
            table.append("\(context.rawValue): \(off.isEmpty ? "one column" : "off column: \(off)")")
        }
        print("menu-text-columns\n" + table.joined(separator: "\n"))
    }
}
