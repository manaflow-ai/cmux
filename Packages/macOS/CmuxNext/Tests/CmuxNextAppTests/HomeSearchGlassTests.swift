import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextTestSupport
import CmuxTheme
@testable import MessagesLabSidebar
import Testing

/// The user, 2026-10-28: "make search look like imessage ui liquid glass too", then the filter
/// button as well (their Messages reference: the filter and compose buttons are round glass
/// circles with a white glyph, Search is a full-width glass capsule with a magnifier and a grey
/// "Search" placeholder). The search field sits on a glass capsule, the Unread filter on a glass
/// circle (Liquid Glass on macOS 26 and later, the frosted material before it), in light and dark.
@Suite(.closesItsWindows)
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

    /// The avatar-only list keeps the filter on its glass, and the search as a glass circle.
    @Test func theAvatarListKeepsTheFilterGlassAndASearchCircle() {
        let home = Self.home(width: 90)
        #expect(!home.unreadToggle.isHidden && !home.filterGlass.isHidden)
        #expect(home.filterGlass.frame == home.unreadToggle.frame)
        #expect(!home.searchButton.isHidden && !home.searchGlass.isHidden)
        #expect(home.searchGlass.frame == home.searchButton.frame)
        #expect(home.searchGlass.cornerRadius == home.searchButton.frame.height / 2)
    }

    /// The search circle opens the search, which then takes the band.
    @Test func theSearchCircleOpensTheSearch() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let home = Self.home(width: 90)
        window.contentView = home
        home.searchButton.performClick(nil)
        home.list.headerView.layoutSubtreeIfNeeded()
        #expect(home.list.searchField.isEditing)
        #expect(home.header.buttonsCovered && home.searchButton.isHidden && home.unreadToggle.isHidden)
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

    /// The user, 2026-10-29 ("search is not centered", 8:41 PM shot): the "Search" placeholder sat
    /// 3 pt above the magnifier and the capsule's middle (AppKit draws an unbezeled field's text at
    /// its frame's top). As in Messages, the magnifier's ink and the placeholder's ink are centred on
    /// the capsule, at every width, and the text being typed sits on the same line.
    @Test(arguments: [180, 320, 480] as [CGFloat])
    func theMagnifierAndPlaceholderAreCentredInTheCapsule(_ width: CGFloat) throws {
        let home = Self.home(width: width)
        let field = home.list.searchField
        field.placeholderAttributedString = NSAttributedString(string: CmuxSidebarView.searchTitle, attributes: [
            .foregroundColor: NSColor.black, .font: field.font ?? .systemFont(ofSize: NSFont.systemFontSize),
        ])
        let capsule = home.searchCapsule.frame
        let fieldFrame = field.frame
        #expect(abs(fieldFrame.midY - capsule.midY) <= 0.5)
        let rep = try #require(field.bitmapImageRepForCachingDisplay(in: field.bounds))
        field.cacheDisplay(in: field.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / field.bounds.width
        let iconSlot = (field.cell as? NSSearchFieldCell)?.searchButtonRect(forBounds: field.bounds) ?? .zero
        let icon = try #require(Self.inkRows(rep, from: 0, to: Int(iconSlot.maxX * scale)), "no magnifier drawn")
        let text = try #require(Self.inkRows(rep, from: Int((iconSlot.maxX + 1) * scale), to: rep.pixelsWide), "no placeholder drawn")
        let middle = CGFloat(rep.pixelsHigh) / 2
        // Within one point of the field's (and so the capsule's) middle; before the fix the
        // placeholder's ink centre sat 3 pt high.
        #expect(abs(icon - middle) / scale <= 1, "the magnifier is \((icon - middle) / scale) pt off centre at \(width)")
        #expect(abs(text - middle) / scale <= 1, "the placeholder is \((text - middle) / scale) pt off centre at \(width)")
    }

    /// The text typed in the field sits on the placeholder's line: the field editor is centred too.
    @Test func theTypedTextIsCentredInTheCapsule() throws {
        let home = Self.home()
        let window = NSWindow(contentRect: home.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = home
        home.layoutSubtreeIfNeeded()
        let field = home.list.searchField
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let box = field.convert(editor.convert(editor.bounds, to: nil), from: nil)
        #expect(abs(box.midY - field.bounds.midY) <= 1, "the field editor is \(box.midY - field.bounds.midY) pt off centre")
    }

    /// https://github.com/manaflow-ai/cmux/issues/27967: once the field took the keyboard, "Search"
    /// and the caret slid left over the magnifier (AppKit puts an unbezeled field's editor in the
    /// frame the cell is handed, the field's whole width). The field editor starts where the
    /// placeholder does at rest, right of the magnifier, at every width.
    @Test(arguments: [180, 320, 480] as [CGFloat])
    func theTypedTextStaysRightOfTheMagnifier(_ width: CGFloat) throws {
        let home = Self.home(width: width)
        let window = NSWindow(contentRect: home.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = home
        home.layoutSubtreeIfNeeded()
        let field = home.list.searchField
        let cell = try #require(field.cell as? NSSearchFieldCell)
        let icon = cell.searchButtonRect(forBounds: field.bounds)
        let rest = cell.searchTextRect(forBounds: field.bounds)
        // AppKit's text rect overlaps its magnifier slot by a point, at rest as well (26 and 27 pt).
        let clear = icon.maxX - 1
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let box = field.convert(editor.convert(editor.bounds, to: nil), from: nil)
        #expect(box.minX >= clear, "the field editor starts \(clear - box.minX) pt over the magnifier at \(width)")
        #expect(abs(box.minX - rest.minX) <= 1, "the field editor starts at \(box.minX), the placeholder at rest at \(rest.minX) (\(width))")
        // Typing shows the cancel button; the editor stays where it started.
        editor.insertText("chief", replacementRange: NSRange(location: 0, length: 0))
        field.layoutSubtreeIfNeeded()
        let typed = field.convert(editor.convert(editor.bounds, to: nil), from: nil)
        #expect(typed.minX >= clear, "with text typed the field editor starts \(clear - typed.minX) pt over the magnifier at \(width)")
    }

    /// The middle (in pixel rows) of the drawn ink between columns `x0` and `x1`; nil when none.
    private static func inkRows(_ rep: NSBitmapImageRep, from x0: Int, to x1: Int) -> CGFloat? {
        var low = Int.max, high = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in max(0, x0)..<min(x1, rep.pixelsWide) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
                low = min(low, y); high = max(high, y)
            }
        }
        return low <= high ? CGFloat(low + high + 1) / 2 : nil
    }
}
