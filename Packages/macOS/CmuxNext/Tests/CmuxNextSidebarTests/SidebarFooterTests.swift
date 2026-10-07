import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// SIDEBAR-FOOTER-MINIMAL (Lawrence 2026-10-06, "this is jank"): the footer
/// is one line with no separator over it: the avatar, then the gear. A
/// staged update is the card above it (UPDATE-CARD, SidebarUpdateCardTests).
/// Before, a hairline sat over a floating "?" button and a "Settings" text
/// row with an accent arrow.
@MainActor @Suite(.serialized) struct SidebarFooterTests {
    private func sidebar(width: CGFloat = 260, intents: ((SidebarIntent) -> Void)? = nil) -> SidebarView {
        let model = SidebarModel()
        model.onIntent = intents
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// No help button and no hairline over the footer: the only band line is
    /// the one under the top band.
    @Test func theFooterHasNoHelpButtonAndNoLine() {
        let view = sidebar()
        #expect(view.footer.subviews.allSatisfy { $0 === view.profileBar }, "only the spaces dots remain in the footer row")
        let lines = (view.layer?.sublayers ?? []).filter { $0.frame.height == Metrics.dividerThickness && !$0.isHidden }
        #expect(lines.allSatisfy { $0 === view.aboveLine })
        #expect(lines.allSatisfy { $0.frame.maxY <= view.belowFade.frame.minY - SidebarStyle.footerHeight })
    }

    /// SIDEBAR-FOOTER-AND-SPACE-MENU F1 (Lawrence 2026-10-06, "too much
    /// padding"): the avatar and the gear are row-height squares side by
    /// side, no gap between them, the avatar's glyph on the column of the
    /// rows' glyphs. Each square stays at least the macOS minimum hit size.
    @Test func theFooterIconsAreEvenSquaresOnTheRowGlyphColumn() throws {
        let view = sidebar()
        let account = try #require(view.belowRegion.itemView(LayoutItemID("itm_account")))
        let gear = try #require(view.belowRegion.itemView(LayoutItemID("itm_settings")))
        let side = Metrics.sidebarRowHeight
        #expect(account.frame.size == CGSize(width: side, height: side), "\(account.frame)")
        #expect(gear.frame.size == account.frame.size)
        #expect(gear.frame.minX == account.frame.maxX, "even spacing, no extra gap: \(account.frame) \(gear.frame)")
        let column = SidebarStyle.horizontalInset * 2 + SidebarStyle.iconBox / 2
        #expect(abs(view.convert(account.frame, from: view.belowRegion).midX - column) <= 0.5)
        #expect(side >= 20, "macOS minimum hit target")
    }
}
