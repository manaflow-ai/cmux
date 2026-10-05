import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// An icon-only built-in item (the account avatar, an icon-only Settings)
/// rests on the tile fill in every arrangement, not only in a grid, and
/// hover is one tonal step stronger than that rest (R97).
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

    static func entered(_ view: NSView) -> NSEvent {
        NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: view.bounds.midX, y: view.bounds.midY), modifierFlags: [],
                               timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    @Test(arguments: [SectionArrangement(layout: .inline, align: .fill), SectionArrangement(layout: .inline, align: .leading)])
    func theAccountRestsOnTheTileFillInAnInlineLine(_ arrangement: SectionArrangement) throws {
        let view = try #require(Self.region(arrangement).itemView(Self.account))
        let rest = view.performWithTheme { Palette.hoverFill }
        #expect(view.fill == rest, "no fill until hover (R97)")
        view.mouseEntered(with: Self.entered(view))
        #expect(view.fill != nil && view.fill != rest, "hover shows a change over the rest fill")
    }

    @Test func aGridTileStillRestsAndHoverIsStronger() throws {
        let view = try #require(Self.region(SectionArrangement(layout: .grid, align: .fill, columns: 8)).itemView(Self.account))
        let rest = view.performWithTheme { Palette.hoverFill }
        #expect(view.fill == rest)
        view.mouseEntered(with: Self.entered(view))
        #expect(view.fill != nil && view.fill != rest, "hover on a resting tile is no longer the same color as rest")
    }
}
