import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// The menu and popover look a theme file sets (``MenuLook``, `appearance.menu.*` and
/// `appearance.popover.*`): unset is today's menu, the native one and the pages'; the Claude desktop
/// fragment (Leo's reference: a 12 pt corner, a dark fill, 30 pt rows, muted shortcuts, flush
/// submenus) reaches the `--menu-*` tokens and the App's ``GlassMenu`` alike.
@MainActor @Suite struct MenuLookTests {
    /// The look the Claude desktop fragment in `theme_file::tests` parses to.
    static var claude: MenuLook {
        var look = MenuLook()
        look.cornerRadius = 12
        look.borderOpacity = 0.1
        look.fill = ThemeRGB(hex: 0x2B2B2B)
        look.padding = 8
        look.highlightRadius = 8
        look.rowHeight = 30
        look.shortcuts = .muted
        look.sectionLabel = .muted
        look.separator = .subtle
        look.submenu = .flush
        look.subtitle = .muted
        look.popoverPadding = 12
        look.popoverHeader = .strong
        look.progressHeight = 6
        return look
    }

    @Test func theStandardLookSendsNoTokens() {
        #expect(MenuLook.standard.webVariables.isEmpty)
        #expect(MenuLook.standard.resolvedPadding == MenuMetrics.highlightInset)
        #expect(MenuLook.Shadow.standard.elevation == PopupStyle.elevation2)
    }

    @Test func theClaudeFragmentReachesTheMenuTokens() {
        let tokens = Self.claude.webVariables
        #expect(tokens["--menu-radius"] == "12px")
        #expect(tokens["--menu-fill"] == "rgba(43, 43, 43, 1.0)")
        #expect(tokens["--menu-border"] == "color-mix(in srgb, currentColor 10%, transparent)")
        #expect(tokens["--menu-padding"] == "8px")
        #expect(tokens["--menu-hover-radius"] == "8px")
        #expect(tokens["--menu-row-height"] == "30px")
        #expect(tokens["--menu-shortcut-color"] == "color-mix(in srgb, currentColor 45%, transparent)")
        #expect(tokens["--menu-separator"] == "color-mix(in srgb, currentColor 6%, transparent)")
        #expect(tokens["--menu-submenu-offset"] == "8px")
        #expect(tokens["--menu-submenu-align-offset"] == "-8px")
        #expect(tokens["--popover-progress-height"] == "6px")
        #expect(tokens["--menu-shadow"] == nil) // standard: the page's own drop
        #expect(tokens.keys.allSatisfy { $0.hasPrefix("--menu-") || $0.hasPrefix("--popover-") })
    }

    @Test func everyShadowFitsTheNativeBand() {
        for shadow in MenuLook.Shadow.allCases {
            guard let elevation = shadow.elevation else { continue }
            #expect(elevation.blur + elevation.offset <= PopupStyle.standard.shadowMargin, "\(shadow)")
        }
        var look = MenuLook()
        look.shadow = .none
        #expect(look.webVariables["--menu-shadow"] == "none")
    }

    @Test func theNativeMenuReadsTheLook() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sign Out", action: nil, keyEquivalent: "")
        let list = GlassMenuListView()
        list.look = Self.claude
        list.load(GlassMenuRow.rows(of: menu))
        #expect(list.fittingMenuSize().height == 8 * 2 + 30 * 2 + GlassMenuListView.separatorHeight)
        let standard = GlassMenuListView()
        standard.load(GlassMenuRow.rows(of: menu))
        #expect(standard.fittingMenuSize().height == MenuMetrics.highlightInset * 2 + GlassMenuMaterial.rowHeight * 2 + GlassMenuListView.separatorHeight)
    }

    @Test func aFlushSubmenuMeetsTheMenuEdgeAndItsRow() {
        let card = CGRect(x: 100, y: 100, width: 240, height: 300)
        let row = CGRect(x: 108, y: 300, width: 224, height: 30)
        let anchor = GlassMenu.flushAnchor(row: row, card: card, padding: 8)
        let screen = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let placed = PopupPlacement.sideBySideFrame(anchor: anchor, size: CGSize(width: 200, height: 120), screen: screen)
        #expect(placed.side == .right)
        #expect(placed.frame.minX == card.maxX)
        // The submenu's first row (its padding below its top) is level with the row.
        #expect(placed.frame.maxY - 8 == row.maxY)
    }
}
