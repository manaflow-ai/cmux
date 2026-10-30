import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxTheme
@testable import MessagesLabSidebar
import Testing

/// The Home list's header (Leo 2026-10-19, "when the thing is compressed"): on the list with names,
/// search, the Unread toggle and New Chief stay on one row at every width; only the search field's
/// width changes; the row sits in the 52 pt band with no lone button above it. Compose is the chat's
/// at every width (the user 2026-10-21, `HomeComposeAndTeamTests`). The avatar-only list shows no row
/// (the user 2026-10-20, as Messages: `HomeNarrowSidebarTests`).
@MainActor
struct HomeSidebarHeaderTests {
    nonisolated static let widths: [CGFloat] = [180, 200, 220, 260, 300, 320, 480]

    @Test(arguments: widths)
    func everythingStaysOnOneRow(_ width: CGFloat) {
        let h = HomeSidebarHeaderLayout(width: width, searchOpen: false)
        let items = [h.search, h.filter, h.newChief]
        #expect(h.compose == .zero)
        #expect(Set(items.map(\.midY)).count == 1, "the row wraps at \(width)")
        #expect(items.allSatisfy { $0.height == HomeSidebarHeaderLayout.side })
        #expect(items.allSatisfy { $0.minX >= 0 && $0.maxX <= width }, "the row overflows \(width)")
        for (a, b) in zip(items, items.dropFirst()) {
            #expect(a.maxX <= b.minX, "items overlap at \(width)")
        }
        #expect(!h.buttonsCovered)
        #expect(h.search.width >= HomeSidebarHeaderLayout.minimumField)
        #expect(h.listTop == HomeSidebarHeaderLayout.band)
    }

    @Test func onlyTheSearchFieldGrowsWithTheWidth() {
        let narrow = HomeSidebarHeaderLayout(width: 200, searchOpen: false)
        let wide = HomeSidebarHeaderLayout(width: 400, searchOpen: false)
        #expect(wide.search.width - narrow.search.width == 200)
        #expect(narrow.filter.size == wide.filter.size)
        #expect(narrow.newChief.size == wide.newChief.size)
        #expect(wide.newChief.maxX == 400 - HomeSidebarHeaderLayout.inset)
    }

    /// The view follows the layout: the field and the quiet buttons on one row, the field's
    /// bezel and AppKit focus ring off, and no fill on a button at rest.
    @Test(arguments: [180, 260, 320] as [CGFloat])
    func theViewDrawsTheRow(_ width: CGFloat) throws {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        home.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
        let field = home.list.searchField
        #expect(field.focusRingType == .none)
        #expect(!field.isBezeled)
        #expect(!field.isHidden)
        #expect(home.compose.isHidden && !home.unreadToggle.isHidden && !home.newChief.isHidden)
        #expect(home.newChief.frame == home.header.newChief)
        #expect(home.newChief.frame.midY == home.unreadToggle.frame.midY)
        #expect(home.unreadToggle.frame == home.header.filter)
        #expect(home.searchCapsule.frame.midY == home.unreadToggle.frame.midY)
        #expect(field.frame.midY == home.unreadToggle.frame.midY)
        // MessagesLab's filter menu button is gone: the toggle is the filter.
        #expect(home.list.controller.filterButton.isHidden)
        for button in [home.newChief, home.unreadToggle] {
            #expect((button.layer?.backgroundColor?.alpha ?? 0) == 0, "a header button has a pill at rest")
        }
    }

    /// Another Chief is one visible click away (it was only in compose's right-click menu, so
    /// Home showed no way to make one).
    @Test func theNewChiefButtonAsksForANewChiefInOneClick() {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        var asked = 0
        var composed = 0
        home.onNewChief = { asked += 1 }
        home.onNewMessage = { composed += 1 }
        home.newChief.performClick(nil)
        #expect(asked == 1)
        #expect(composed == 0)
        #expect(home.newChief.accessibilityIdentifier() == "cmux.home.sidebar.newChief")
        #expect(home.newChief.accessibilityLabel() == HomeConversationStrings.chiefTitle)
    }

    /// The field's text is centred on the row (Leo 2026-10-19, "vertically they need to all be
    /// centered"): an unbezeled search cell draws its line from the frame's top, so the field is
    /// one text line tall and centred in its capsule, on the buttons' centre line.
    @Test(arguments: [260, 320, 480] as [CGFloat])
    func theSearchTextIsCentredOnTheRow(_ width: CGFloat) throws {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        home.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
        let field = home.list.searchField
        let font = try #require(field.font)
        #expect(field.frame.height == ceil(NSLayoutManager().defaultLineHeight(for: font)))
        #expect(abs(field.frame.midY - home.searchCapsule.frame.midY) <= 0.5)
        #expect(abs(field.frame.midY - home.unreadToggle.frame.midY) <= 0.5)
    }

    /// The header's glyphs share one centre line by what they draw (Leo 2026-10-19, "vertically
    /// they need to all be centered"): SF Symbols centre their layout box, and compose's pencil tip
    /// lifts its box, so its square sat 1.75 pt below the other glyphs.
    @Test(arguments: ["square.and.pencil", "plus.bubble", "line.3.horizontal.decrease.circle"])
    func eachHeaderGlyphHasItsInkCentred(_ name: String) throws {
        let image = try #require(HomeHeaderButton.centredSymbol(name, size: 14))
        #expect(image.isTemplate)
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let ink = try #require(HomeHeaderButton.inkBounds(cg))
        let scale = CGFloat(cg.width) / image.size.width
        #expect(abs(ink.midY / scale - image.size.height / 2) <= 0.5, "\(name) ink is off centre vertically")
        #expect(abs(ink.midX / scale - image.size.width / 2) <= 0.5, "\(name) ink is off centre horizontally")
    }

    @Test func theUnreadToggleFiltersInOneClick() {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        #expect(!home.unreadOnly)
        home.unreadToggle.performClick(nil)
        #expect(home.unreadOnly)
        #expect(home.unreadToggle.isOn)
        #expect(home.list.controller.filter == .unread)
        home.unreadToggle.performClick(nil)
        #expect(home.list.controller.filter == .all)
        #expect(!home.unreadToggle.isOn)
    }

    /// live-qa on nightly 3a63d6d: in light mode the compose and filter glyphs did not draw at all.
    /// A button has its glyph from the start and at its size as soon as the header sets its frame,
    /// without waiting for the button's own layout pass.
    @Test func theGlyphIsThereBeforeAnyLayout() throws {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        for button in [home.compose, home.newChief, home.unreadToggle] {
            #expect(button.image != nil, "\(button.accessibilityIdentifier()) has no glyph before layout")
            button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
            #expect(button.glyphSize == 14, "the glyph waited for layout() to take the 28 pt button's size")
            #expect(button.image != nil)
        }
    }

    /// A light/dark switch of the scope the list draws in rebuilds each header glyph in the new
    /// tint (the theme's secondary text): a new image, never the dark one left on screen.
    @Test func theHeaderGlyphsAreRebuiltOnALightDarkSwitch() throws {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        let scope = ThemeScope(level: .room)
        scope.root(home)
        func paint(background: UInt32, foreground: UInt32) throws {
            let input = ThemeInput(background: ThemeRGB(hex: background), foreground: ThemeRGB(hex: foreground))
            scope.setOverride(try #require(ThemeSpec("Home Header Glyphs")), input: input, animated: false)
            home.layoutSubtreeIfNeeded()
            home.list.headerView.needsLayout = true
            home.list.headerView.layoutSubtreeIfNeeded()
        }
        let buttons = [home.compose, home.newChief, home.unreadToggle]
        try paint(background: 0x1C1C1F, foreground: 0xE6E6E6)
        #expect(scope.tokens.isDark)
        let dark = try buttons.map { button in (image: try #require(button.image), tint: try #require(button.glyphTint)) }

        try paint(background: 0xFEFFFF, foreground: 0x1C1C1F)
        #expect(!scope.tokens.isDark)
        for (button, before) in zip(buttons, dark) {
            let name = button.accessibilityIdentifier()
            let image = try #require(button.image, "\(name) lost its glyph on the switch to light")
            #expect(image !== before.image, "\(name) kept its dark glyph image")
            let tint = try #require(button.glyphTint)
            #expect(tint != before.tint, "\(name) kept its dark tint")
            // The list's quiet compose glyph is the secondary text; the Unread filter's, on its
            // glass circle, the primary text (Messages' white glyph on glass).
            let expected = button === home.unreadToggle ? button.performWithTheme { Palette.textPrimary }
                : button.performWithTheme { Palette.textSecondary }
            #expect(tint == expected)
            #expect(button.contentTintColor == tint)
        }
        // The glyph keeps its size across the switch: half the Unread toggle's height. The list's compose button is
        // hidden and zero-sized since 1cc2f1b57d133 (compose is the chat's at every width), so its glyph is the 10 pt floor.
        #expect(home.unreadToggle.frame.height == HomeSidebarHeaderLayout.side
            && home.unreadToggle.glyphSize == HomeSidebarHeaderLayout.side / 2)
        #expect(home.newChief.frame.height == HomeSidebarHeaderLayout.side
            && home.newChief.glyphSize == HomeSidebarHeaderLayout.side / 2)
        #expect(home.compose.frame.size == .zero && home.compose.glyphSize == 10)
    }
}
