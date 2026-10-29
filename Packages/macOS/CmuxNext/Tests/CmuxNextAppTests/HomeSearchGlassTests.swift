import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxTheme
@testable import MessagesLabSidebar
import Testing

/// The user, 2026-10-28: "make search look like imessage ui liquid glass too", then the filter
/// button as well (their Messages reference: the filter and compose buttons are round glass
/// circles with a white glyph, Search is a full-width glass capsule with a magnifier and a grey
/// "Search" placeholder). The search field sits on a glass capsule, the Unread filter on a glass
/// circle (Liquid Glass on macOS 26 and later, the frosted material before it), in light and dark.
@MainActor
struct HomeSearchGlassTests {
    private static func home(width: CGFloat = 320) -> HomeSidebarView {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        home.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
        return home
    }

    @Test(arguments: [180, 260, 320, 480] as [CGFloat])
    func theSearchFieldSitsOnAGlassCapsule(_ width: CGFloat) throws {
        let home = Self.home(width: width)
        let capsule = home.searchCapsule
        let glass = capsule.glass
        #expect(glass.superview === capsule)
        #expect(glass.frame == capsule.bounds)
        #expect(glass.isLiquidGlass == Glass.isLiquidGlassAvailable)
        #expect(glass.cornerRadius == capsule.bounds.height / 2, "the glass is not a capsule at \(width)")
        // No flat fill or rim over the glass at rest: the glass is the field's whole look.
        #expect((capsule.layer?.backgroundColor?.alpha ?? 0) == 0)
        #expect((capsule.layer?.borderWidth ?? 0) == 0 || (capsule.layer?.borderColor?.alpha ?? 0) == 0)
        // Messages' row: the field as tall as the filter circle, centred on it.
        #expect(capsule.frame.height == home.unreadToggle.frame.height)
        #expect(capsule.frame.midY == home.unreadToggle.frame.midY)
    }

    @Test(arguments: [180, 260, 320, 480] as [CGFloat])
    func theFilterIsAGlassCircle(_ width: CGFloat) throws {
        let home = Self.home(width: width)
        let toggle = home.unreadToggle
        let glass = home.filterGlass
        #expect(glass.superview === toggle.superview)
        #expect(glass.frame == toggle.frame)
        #expect(toggle.frame.width == toggle.frame.height, "the filter is not round at \(width)")
        #expect(glass.cornerRadius == toggle.frame.height / 2)
        #expect(glass.isLiquidGlass == Glass.isLiquidGlassAvailable)
        #expect(glass.isHidden == toggle.isHidden)
        // Below the button, so the glyph draws on the glass.
        let siblings = try #require(toggle.superview?.subviews)
        let below = try #require(siblings.firstIndex(of: glass))
        let above = try #require(siblings.firstIndex(of: toggle))
        #expect(below < above)
    }

    /// The avatar-only list hides the filter, and its glass with it.
    @Test func theAvatarListHidesTheFilterGlass() {
        let home = Self.home(width: 90)
        #expect(home.unreadToggle.isHidden)
        #expect(home.filterGlass.isHidden)
    }

    /// Messages' filter glyph: three lines, no ring, in the text colour (white on dark), in light
    /// and dark; on while only unread conversations show, the lit glyph.
    @Test func theFilterGlyphIsMessagesInLightAndDark() throws {
        let home = Self.home()
        let scope = ThemeScope(level: .room)
        scope.root(home)
        for (background, foreground) in [(0x1C1C1F, 0xE6E6E6), (0xFEFFFF, 0x1C1C1F)] as [(UInt32, UInt32)] {
            let input = ThemeInput(background: ThemeRGB(hex: background), foreground: ThemeRGB(hex: foreground))
            scope.setOverride(try #require(ThemeSpec("Home Search Glass")), input: input, animated: false)
            home.layoutSubtreeIfNeeded()
            let toggle = home.unreadToggle
            #expect(toggle.glyphName == "line.3.horizontal.decrease")
            #expect(toggle.glyphTint == toggle.performWithTheme { Palette.textPrimary })
            // The placeholder is the quiet grey, the text the primary colour.
            let field = home.list.searchField
            let placeholder = try #require(field.placeholderAttributedString)
            let color = placeholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            #expect(color == field.performWithTheme { Palette.textSecondary })
            #expect(placeholder.string == CmuxSidebarView.searchTitle)
        }
        home.unreadOnly = true
        #expect(home.unreadToggle.glyphName == "line.3.horizontal.decrease")
        #expect(home.unreadToggle.glyphTint == home.unreadToggle.performWithTheme { Palette.litGlyph })
    }

    /// Under the traffic lights (the window's sidebar closed) the filter circle stays on their line
    /// and inside the header, and the search capsule spans the list under them.
    @Test(arguments: [200, 320, 480] as [CGFloat])
    func theGlassFitsUnderTheLights(_ width: CGFloat) {
        let lights = CGRect(x: 7, y: 9, width: 52, height: 14)
        let h = HomeSidebarHeaderLayout(width: width, searchOpen: false, windowControls: lights)
        #expect(h.filter.width == h.filter.height)
        #expect(h.filter.minY >= 0, "the filter circle runs off the window's top at \(width)")
        #expect(h.filter.midY == lights.midY)
        #expect(h.search.height == HomeSidebarHeaderLayout.side)
        #expect(h.search.minY >= h.filter.maxY, "the search capsule overlaps the filter's row at \(width)")
    }
}
