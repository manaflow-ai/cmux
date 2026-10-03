import CoreGraphics
import Testing
@testable import CmuxNextSidebar

/// The rail look (plans/cmux-next/sidebar-sections.md 11): the sticky
/// bands as one icon column, the band above the workspace list from the
/// top and the band below it pinned to the bottom, lines between sections,
/// and overflow into a More button when the column is short.
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

    /// The default rail (Leo, 2026-10-03; the Codex app's skinny strip):
    /// Home, the App Store, History and Notifications from the top, then a
    /// More button holding Settings, Customize Appearance and CodeRouter
    /// (the top section's `maxRows` is 4), and the account pinned to the
    /// bottom.
    @Test func theDefaultRailIsFourDestinationsThenMoreWithTheAccountAtTheBottom() {
        let rail = SidebarRailLayout.make(document: .defaults, room: nil, height: 600, metrics: m)
        #expect(rail.buttons.map(\.item.rawValue) == ["itm_home", "itm_app_store", "itm_history", "itm_notifications", "itm_account"])
        #expect(rail.overflow.map(\.rawValue) == ["itm_settings", "itm_customize", "itm_app_coderouter"])
        let frames = rail.buttons.map(\.frame)
        #expect(frames[0] == CGRect(x: 7, y: 40, width: 34, height: 34))
        #expect(frames[1].minY == frames[0].maxY + 4)
        // More takes the slot after the last destination.
        #expect(rail.more == CGRect(x: 7, y: frames[3].maxY + 4, width: 34, height: 34))
        // The bottom band ends at the bottom inset.
        #expect(frames[4].maxY == CGFloat(588))
        // One section per band: no lines.
        #expect(rail.separators.isEmpty)
    }

    /// A section's `maxRows` caps its buttons in the rail: the rest go
    /// under More, which sits right after the capped section's buttons; a
    /// section without a cap shows every item.
    @Test func maxRowsCapsASectionAndMoreFollowsIt() {
        var capped = section("a", region: .top, refs: [.builtIn(.home), .builtIn(.history), .builtIn(.notifications)])
        capped.maxRows = 1
        let doc = document([capped, section("b", region: .top, refs: [.builtIn(.bookmarks)])])
        let rail = SidebarRailLayout.make(document: doc, room: nil, height: 600, metrics: m)
        #expect(rail.buttons.map(\.item.rawValue) == ["a_0", "b_0"])
        #expect(rail.overflow.map(\.rawValue) == ["a_1", "a_2"])
        #expect(rail.more == CGRect(x: 7, y: 40 + 34 + 4, width: 34, height: 34))
        // The line before section b comes after the More button.
        #expect(rail.separators == [CGRect(x: 12, y: 40 + 34 + 4 + 34 + 8, width: 24, height: 1)])
        #expect(rail.buttons[1].frame.minY == CGFloat(40 + 34 + 4 + 34 + 8 + 1 + 8))

        // A cap at or above the item count changes nothing.
        capped.maxRows = 3
        let uncapped = SidebarRailLayout.make(document: document([capped]), room: nil, height: 600, metrics: m)
        #expect(uncapped.overflow.isEmpty && uncapped.more == nil)
        #expect(uncapped.buttons.count == 3)
    }

    /// A short rail still overflows by height: buttons that reach the
    /// bottom band join the capped items under the one More button, in
    /// document order.
    @Test func aShortCappedRailOverflowsIntoTheSameMore() {
        var capped = section("a", region: .top, refs: [.builtIn(.home), .builtIn(.history), .builtIn(.notifications), .builtIn(.bookmarks)])
        capped.maxRows = 3
        let doc = document([capped, section("z", region: .bottom, refs: [.builtIn(.account)])])
        // a_0 40-74, a_1 78-112, a_2 116-150, More 154-188; the limit is 240 - 12 - 34 - 8 = 186.
        let rail = SidebarRailLayout.make(document: doc, room: nil, height: 240, metrics: m)
        #expect(rail.buttons.map(\.item.rawValue) == ["a_0", "a_1", "z_0"])
        #expect(rail.overflow.map(\.rawValue) == ["a_2", "a_3"])
        #expect(rail.more == CGRect(x: 7, y: 116, width: 34, height: 34))
    }

    @Test func aLineSeparatesSectionsOfOneBand() {
        let doc = document([section("a", region: .top, refs: [.builtIn(.home)]),
                            section("b", region: .top, refs: [.builtIn(.history), .builtIn(.notifications)])])
        let rail = SidebarRailLayout.make(document: doc, room: nil, height: 600, metrics: m)
        #expect(rail.separators == [CGRect(x: 12, y: 40 + 34 + 8, width: 24, height: 1)])
        let b0 = rail.buttons.first { $0.item.rawValue == "b_0" }!
        // Top inset, a button, the gap, the line, the gap.
        let expected: CGFloat = 40 + 34 + 8 + 1 + 8
        #expect(b0.frame.minY == expected)
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
        #expect(rail.buttons.last!.frame.maxY == CGFloat(588))
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

    /// A short rail keeps the bottom band and moves top buttons that would
    /// reach it into a More button, which takes the last slot that fits
    /// (its item joins the list); a section that lost every button loses
    /// its line.
    @Test func aShortRailOverflowsTheTopBandIntoMore() {
        let doc = document([section("a", region: .top, refs: [.builtIn(.home), .builtIn(.history)]),
                            section("b", region: .top, refs: [.builtIn(.notifications)]),
                            section("z", region: .bottom, refs: [.builtIn(.settings)])])
        // 40 top + 34 + 4 + 34 = 112 for section a; the bottom button sits at 160 - 12 - 34 = 114.
        let rail = SidebarRailLayout.make(document: doc, room: nil, height: 160, metrics: m)
        #expect(rail.buttons.map(\.item.rawValue) == ["z_0"])
        #expect(rail.overflow.map(\.rawValue) == ["a_0", "a_1", "b_0"])
        #expect(rail.more?.minY == CGFloat(40))
        #expect(rail.separators.isEmpty)
        #expect((rail.more?.maxY ?? .infinity) <= CGFloat(106))
    }

    /// The More button keeps the line of the section whose slot it takes.
    @Test func moreKeepsTheLineOfItsSection() {
        let doc = document([section("a", region: .top, refs: [.builtIn(.home)]),
                            section("b", region: .top, refs: [.builtIn(.history), .builtIn(.notifications)]),
                            section("z", region: .bottom, refs: [.builtIn(.settings)])])
        // a_0 40-74, line 82, b_0 91-125, b_1 129-163; the limit is 200 - 12 - 34 - 8 = 146.
        let rail = SidebarRailLayout.make(document: doc, room: nil, height: 200, metrics: m)
        #expect(rail.buttons.map(\.item.rawValue) == ["a_0", "z_0"])
        #expect(rail.overflow.map(\.rawValue) == ["b_0", "b_1"])
        #expect(rail.more == CGRect(x: 7, y: 91, width: 34, height: 34))
        #expect(rail.separators.map(\.minY) == [CGFloat(82)])
    }

    /// Without caps (the layout before the rail defaults) a tall rail shows
    /// everything.
    @Test func nothingOverflowsAndNoMoreWhenEverythingFits() {
        let rail = SidebarRailLayout.make(document: SidebarLayoutDocument.preRailDefaults, room: nil, height: 600, metrics: m)
        #expect(rail.overflow.isEmpty)
        #expect(rail.more == nil)
    }

    @Test func buttonAtFindsTheButtonUnderThePoint() {
        let rail = SidebarRailLayout.make(document: .defaults, room: nil, height: 600, metrics: m)
        #expect(rail.button(at: CGPoint(x: 24, y: 57))?.item.rawValue == "itm_home")
        #expect(rail.button(at: CGPoint(x: 24, y: 300)) == nil)
    }
}
