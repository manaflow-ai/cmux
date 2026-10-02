import CoreGraphics
import Testing
@testable import CmuxNextSidebar

/// The rail look (plans/cmux-next/sidebar-sections.md 11): the sticky
/// bands as one icon column, the band above the workspace list from the
/// top and the band below it pinned to the bottom, lines between sections,
/// and overflow when the column is short.
@Suite struct SidebarRailLayoutTests {
    private let m = SidebarRailMetrics(width: 48, buttonSize: 34, buttonGap: 4, sectionGap: 8, lineWidth: 1,
                                       lineInset: 12, topInset: 40, bottomInset: 12)

    private func section(_ id: String, region: SidebarRegion, room: String? = nil, refs: [LayoutItemRef]) -> LayoutSection {
        LayoutSection(id: LayoutSectionID(id), region: region, look: .builtIn, room: room,
                      items: refs.enumerated().map { LayoutItem(id: LayoutItemID("\(id)_\($0.offset)"), ref: $0.element) })
    }

    private func document(_ sections: [LayoutSection]) -> SidebarLayoutDocument {
        SidebarLayoutDocument(sections: sections + [LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle,
                                                                   content: .workspaces)])
    }

    @Test func theDefaultLayoutPutsHomeOnTopAndSettingsWithTheAccountAtTheBottom() {
        let rail = SidebarRailLayout.make(document: .defaults, room: nil, height: 600, metrics: m)
        #expect(rail.buttons.map(\.item.rawValue) == ["itm_home", "itm_app_store", "itm_settings", "itm_account"])
        let frames = rail.buttons.map(\.frame)
        #expect(frames[0] == CGRect(x: 7, y: 40, width: 34, height: 34))
        #expect(frames[1].minY == frames[0].maxY + 4)
        // The bottom band ends at the bottom inset.
        #expect(frames[3].maxY == 600 - 12)
        #expect(frames[2].maxY + 4 == frames[3].minY)
        // One section per band: no lines.
        #expect(rail.separators.isEmpty)
        #expect(rail.overflow.isEmpty)
    }

    @Test func aLineSeparatesSectionsOfOneBand() {
        let doc = document([section("a", region: .top, refs: [.builtIn(.home)]),
                            section("b", region: .top, refs: [.builtIn(.history), .builtIn(.notifications)])])
        let rail = SidebarRailLayout.make(document: doc, room: nil, height: 600, metrics: m)
        #expect(rail.separators == [CGRect(x: 12, y: 40 + 34 + 8, width: 24, height: 1)])
        let b0 = rail.buttons.first { $0.item.rawValue == "b_0" }!
        #expect(b0.frame.minY == 40 + 34 + 8 + 1 + 8)
    }

    /// Under `appearance.borders = none` the line draws nothing and the
    /// spacing stays, so nothing moves.
    @Test func noBordersKeepsTheSpacing() {
        let doc = document([section("a", region: .top, refs: [.builtIn(.home)]),
                            section("b", region: .top, refs: [.builtIn(.history)])])
        var none = m
        none.lineWidth = 0
        let lined = SidebarRailLayout.make(document: doc, room: nil, height: 600, metrics: m)
        let bare = SidebarRailLayout.make(document: doc, room: nil, height: 600, metrics: none)
        #expect(bare.separators.allSatisfy { $0.height == 0 })
        #expect(bare.buttons.last!.frame.minY == lined.buttons.last!.frame.minY - 1)
    }

    /// The bands split at the Workspaces section wherever it is, like the
    /// sidebar's own bands; the Workspaces section itself never shows.
    @Test func theWorkspacesSectionSplitsTheBandsAndNeverShows() {
        let doc = SidebarLayoutDocument(sections: [
            section("a", region: .top, refs: [.builtIn(.home)]),
            section("b", region: .top, refs: [.builtIn(.history)]),
            LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .top, content: .workspaces),
            section("c", region: .top, refs: [.builtIn(.settings)]),
        ])
        let rail = SidebarRailLayout.make(document: doc, room: nil, height: 600, metrics: m)
        #expect(rail.buttons.map(\.item.rawValue) == ["a_0", "b_0", "c_0"])
        #expect(rail.buttons.last!.frame.maxY == 600 - 12)
    }

    @Test func roomScopedSectionsShowOnlyInTheirRoom() {
        let doc = document([section("a", region: .top, refs: [.builtIn(.home)]),
                            section("p", region: .top, room: "room_x", refs: [.url("https://example.com")])])
        #expect(SidebarRailLayout.make(document: doc, room: nil, height: 600, metrics: m).buttons.count == 1)
        #expect(SidebarRailLayout.make(document: doc, room: "room_x", height: 600, metrics: m).buttons.count == 2)
    }

    /// Unknown kinds and built-ins from a newer client render nothing
    /// (L5), and a section left empty draws no line.
    @Test func unknownItemsAndEmptySectionsDrawNothing() {
        let doc = document([section("a", region: .top, refs: [.builtIn(.home)]),
                            section("u", region: .top, refs: [LayoutItemRef(kind: "future", value: "x"),
                                                             LayoutItemRef(kind: LayoutItemRef.builtInKind, value: "tasks")]),
                            section("e", region: .top, refs: [])])
        let rail = SidebarRailLayout.make(document: doc, room: nil, height: 600, metrics: m)
        #expect(rail.buttons.map(\.item.rawValue) == ["a_0"])
        #expect(rail.separators.isEmpty)
    }

    /// A short rail keeps the bottom band and drops top buttons that would
    /// reach it, with the line of a section that lost every button.
    @Test func aShortRailOverflowsTheTopBand() {
        let doc = document([section("a", region: .top, refs: [.builtIn(.home), .builtIn(.history)]),
                            section("b", region: .top, refs: [.builtIn(.notifications)]),
                            section("z", region: .bottom, refs: [.builtIn(.settings)])])
        // 40 top + 34 + 4 + 34 = 112 for section a; the bottom button sits at 160 - 12 - 34 = 114.
        let rail = SidebarRailLayout.make(document: doc, room: nil, height: 160, metrics: m)
        #expect(rail.buttons.map(\.item.rawValue) == ["a_0", "z_0"])
        #expect(rail.overflow.map(\.rawValue) == ["a_1", "b_0"])
        #expect(rail.separators.isEmpty)
        for button in rail.buttons where button.section != LayoutSectionID("z") {
            #expect(button.frame.maxY <= 114 - 8)
        }
    }

    @Test func buttonAtFindsTheButtonUnderThePoint() {
        let rail = SidebarRailLayout.make(document: .defaults, room: nil, height: 600, metrics: m)
        #expect(rail.button(at: CGPoint(x: 24, y: 57))?.item.rawValue == "itm_home")
        #expect(rail.button(at: CGPoint(x: 24, y: 300)) == nil)
    }
}
