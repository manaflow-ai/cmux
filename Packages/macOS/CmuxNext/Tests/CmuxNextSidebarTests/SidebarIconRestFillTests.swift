import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// An icon-only built-in item (the account avatar, an icon-only Settings)
/// has no fill at rest in any arrangement and shows the hover fill on hover
/// (Lawrence 2026-10-05: "account icon should not have bg unless i hover";
/// this replaces R97's resting tile fill). In R53's grid row it is a square
/// button, so its glyph has the same room on all four sides; the default
/// footer is the avatar then the gear, both bare icons
/// (SIDEBAR-FOOTER-MINIMAL).
@MainActor @Suite struct SidebarIconRestFillTests {
    static let account = LayoutItemID("itm_account")

    static func region(_ arrangement: SectionArrangement) -> SidebarRegionView {
        let section = LayoutSection(id: LayoutSectionID("bottom"), region: .bottom, look: .builtIn, arrangement: arrangement, items: [
            LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings)),
            LayoutItem(id: account, ref: .builtIn(.account), showsLabel: false),
        ])
        let region = SidebarRegionView(region: .bottom)
        let content = SidebarRegionView.Content(sections: [section], infos: [:], collapsed: [], look: .quiet,
                                                metrics: .standard, drawsLines: true)
        region.update(content, width: 240)
        return region
    }

    /// Hosts `view`'s region in a window and rests the injected pointer on
    /// `view` (`PointerHover`, cx-3wu5). The caller closes the window.
    static func hover(_ view: NSView) throws -> NSWindow {
        var root = view
        while let parent = root.superview { root = parent }
        // A region sizes only its rows; give it room so the rows are visible.
        if root.frame.height < 1 { root.frame = NSRect(x: 0, y: 0, width: 240, height: 400) }
        let window = SidebarHoverOwnerTests.window()
        window.contentView!.addSubview(root)
        do {
            try SidebarHoverOwnerTests.rest(on: view, at: SidebarHoverOwnerTests.center(view))
        } catch {
            PointerHover.clearDebugPointer(in: window)
            window.close()
            throw error
        }
        return window
    }

    @Test(arguments: [SectionArrangement(layout: .inline, align: .fill), SectionArrangement(layout: .inline, align: .leading)])
    func theAccountHasNoFillUntilHoverInAnInlineLine(_ arrangement: SectionArrangement) throws {
        let view = try #require(Self.region(arrangement).itemView(Self.account))
        #expect(view.fill == nil, "no background at rest")
        let window = try Self.hover(view)
        defer { PointerHover.clearDebugPointer(in: window); window.close() }
        #expect(view.fill != nil, "hover shows the background")
    }

    @Test func aGridTileHasNoFillUntilHover() throws {
        let view = try #require(Self.region(SectionArrangement(layout: .grid, align: .fill, columns: 8)).itemView(Self.account))
        #expect(view.fill == nil)
        let window = try Self.hover(view)
        defer { PointerHover.clearDebugPointer(in: window); window.close() }
        #expect(view.fill != nil)
    }

    /// R53's grid row (Settings over 7 of 8 columns, the account over 1): the account is
    /// a row-height square at the row's trailing inset, so the glyph's padding is equal on all
    /// sides (it was 25 x 32 at 240 points: 3.5 points beside the glyph, 7 above and below), and
    /// Settings takes the rest of the line.
    @Test func theGridAccountButtonIsSquareAndSettingsFillsTheRest() throws {
        let bottom = SidebarLayoutDocument.gridBottomSection
        let region = SidebarRegionView(region: .bottom)
        let metrics = SidebarRegionMetrics.standard
        region.update(SidebarRegionView.Content(sections: [bottom], infos: [:], collapsed: [], look: .quiet,
                                                metrics: metrics, drawsLines: true), width: 240)
        let account = try #require(region.itemView(Self.account)).frame
        let settings = try #require(region.itemView(LayoutItemID("itm_settings"))).frame
        #expect(account.width == account.height, "square: \(account)")
        #expect(account.height == metrics.rowHeight)
        #expect(account.minY == settings.minY && account.height == settings.height, "same row, same height")
        #expect(abs((240 - account.maxX) - settings.minX) < 0.5, "the same inset at both ends: \(settings) \(account)")
        #expect(abs(account.minX - settings.maxX - (bottom.arrangement.gap.map { CGFloat($0) } ?? metrics.tileGap)) < 0.5,
                "one gap between Settings and the account")
    }

    /// SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2: the default footer line is the account
    /// alone, a bare icon at the leading inset; no fill until hover, and the glyph goes from
    /// the secondary to the primary text color on hover. (With the App's profile avatar it
    /// draws the profile control, SidebarProfileControlTests.)
    @Test func theDefaultFooterIsTheAccountAsABareIcon() throws {
        let bottom = try #require(SidebarLayoutDocument.defaults.section(SidebarLayoutDocument.bottomSectionID))
        #expect(bottom.items.map(\.id.rawValue) == ["itm_account"])
        #expect(bottom.items.allSatisfy { !$0.showsLabel && $0.span == nil })
        let region = SidebarRegionView(region: .bottom)
        let metrics = SidebarRegionMetrics.standard
        region.update(SidebarRegionView.Content(sections: [bottom], infos: [:], collapsed: [], look: .quiet,
                                                metrics: metrics, drawsLines: true), width: 240)
        let account = try #require(region.itemView(Self.account))
        #expect(account.style == .icon)
        // Leading, its glyph on the rows' glyph column (F1).
        let column = SidebarStyle.horizontalInset * 2 + SidebarStyle.iconBox / 2
        #expect(abs(account.frame.midX - column) <= 0.5, "leading: \(account.frame)")
        #expect(account.fill == nil, "no background at rest")
        account.updateLayer()
        #expect(account.glyphTint == account.performWithTheme { Palette.textSecondary })
        let window = try Self.hover(account)
        defer { PointerHover.clearDebugPointer(in: window); window.close() }
        account.updateLayer()
        #expect(account.fill != nil, "hover shows the background")
        #expect(account.glyphTint == account.performWithTheme { Palette.textPrimary }, "full strength on hover")
    }
}
