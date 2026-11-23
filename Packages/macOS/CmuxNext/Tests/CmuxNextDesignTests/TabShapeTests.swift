import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import Testing

/// `appearance.tabShape` (Leo, 2026-11-18: "the blockiness of tabs both horizontal the the vertical ones in the sidebar
/// should be customized/customizable too. like the "gooey" is each tab looking like it's morphing into the visible pane.
/// the two tone thing."): block draws today's chrome, rounded makes capsules; the gooey look is `appearance.cornerFlush`
/// flush-goo, which on a block shape flares the selected tab and sidebar row into the card on two tones.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabShapeTests {
    @Test func blockIsTheDefaultAndDrawsTodaysChrome() {
        let design = DesignSettings.shared
        let before = (design.densityTokens, design.chromeStyle, design.tabShape, design.titleAreaTone)
        defer { (design.densityTokens, design.chromeStyle, design.tabShape, design.titleAreaTone) = before }
        #expect(TabShape.allCases.first == .block)
        design.densityTokens = DensityPreset.cozy.tokens
        design.chromeStyle = .flat
        design.titleAreaTone = .oneColor
        design.tabShape = .block
        #expect(CornerFlush.current == .flush, "block keeps the default flush corner, no goo")
        #expect(Metrics.titleAreaShadeScale == 0, "block keeps One Color's single colour")
        #expect(TabShape.block.fillCornerRadius(6, height: 28, tabHeight: 28) == 6)
    }

    /// The gooey look is `appearance.cornerFlush` flush-goo, not a third tab shape: on a block shape it flares the
    /// selected tab and the selected sidebar row into the card, on two tones; rounded keeps capsules.
    @Test func gooIsTheCornerFlushAndReachesTheSidebarOnTwoTones() {
        let design = DesignSettings.shared
        let before = (design.densityTokens, design.chromeStyle, design.tabShape, design.titleAreaTone, design.titleAreaContrast,
                      design.cornerFlush)
        defer {
            (design.densityTokens, design.chromeStyle, design.tabShape, design.titleAreaTone, design.titleAreaContrast,
             design.cornerFlush) = before
        }
        design.densityTokens = DensityPreset.cozy.tokens
        design.chromeStyle = .flat
        design.titleAreaTone = .oneColor
        design.titleAreaContrast = 1
        design.tabShape = .block
        design.cornerFlush = nil
        #expect(!CornerFlush.sidebarRowFlows, "the default flush corner keeps today's sidebar rows")
        design.cornerFlush = .goo
        #expect(CornerFlush.current == .goo && CornerFlush.current.feetRadius > 0)
        #expect(CornerFlush.sidebarRowFlows, "goo on a block shape runs the sidebar's selected row into the card")
        #expect(Metrics.titleAreaShadeScale == TitleAreaTone.subtleShare, "goo tones the frame even under One Color")
        design.tabShape = .rounded
        #expect(!CornerFlush.sidebarRowFlows, "rounded keeps the sidebar's rows capsules under goo")
        design.tabShape = .block
        design.densityTokens = .compact
        #expect(CornerFlush.current == .off && !CornerFlush.sidebarRowFlows, "compact keeps the pill")
    }

    @Test func roundedIsACapsuleThatNeverRunsIntoTheCard() {
        #expect(!TabShape.rounded.runsIntoCard)
        #expect(TabShape.block.runsIntoCard)
        #expect(TabShape.rounded.fillCornerRadius(6, height: 28, tabHeight: 28) == 14)
        #expect(TabShape.rounded.fillCornerRadius(6, height: 48, tabHeight: 28) == 14, "a tall row's ends as round as a tab's")
        #expect(TabShape.rounded.fillCornerRadius(0, height: 28, tabHeight: 28) == 0, "a row with no rounded fill keeps none")
    }

    /// The goo's sidebar row: out to the card's edge, rounded on the far side only, with a fillet above and below at
    /// the card's edge; mirrored for a sidebar on the right; nil where it would reach the card's rounded corners.
    @Test func theSidebarRowRunsToTheCardWithFillets() throws {
        let card = CGRect(x: 200, y: 10, width: 600, height: 500) // unflipped: the top is maxY
        let row = CGRect(x: 12, y: 300, width: 176, height: 28)
        let path = try #require(CornerFlushChrome.sidebarFolderPath(row: row, card: card, cardRadius: 12, rowRadius: 6, feet: 8))
        #expect(path.contains(CGPoint(x: 199.5, y: 314)), "the row reaches the card's edge")
        #expect(path.contains(CGPoint(x: 200.5, y: 314)), "and a point past it, so no seam shows")
        #expect(!path.contains(CGPoint(x: 12.3, y: 300.3)), "the far side keeps its rounded corner")
        #expect(path.contains(CGPoint(x: 187.5, y: 300.5)), "the card's side is square")
        #expect(path.contains(CGPoint(x: 199.5, y: 328.5)), "a fillet above, at the card's edge")
        #expect(path.contains(CGPoint(x: 199.5, y: 299.5)), "and one below")
        #expect(!path.contains(CGPoint(x: 192.5, y: 335.5)), "the fillet is concave")
        #expect(!path.contains(CGPoint(x: 199.5, y: 337)), "it ends one radius above the row")

        let right = CGRect(x: 812, y: 300, width: 176, height: 28)
        let mirrored = try #require(CornerFlushChrome.sidebarFolderPath(row: right, card: card, cardRadius: 12, rowRadius: 6, feet: 8))
        #expect(mirrored.contains(CGPoint(x: 800.5, y: 314)) && mirrored.contains(CGPoint(x: 800.5, y: 328.5)))

        let underTheTabRow = CGRect(x: 12, y: 490, width: 176, height: 28)
        #expect(CornerFlushChrome.sidebarFolderPath(row: underTheTabRow, card: card, cardRadius: 12, rowRadius: 6, feet: 8) == nil)
        let overlapping = CGRect(x: 12, y: 300, width: 300, height: 28)
        #expect(CornerFlushChrome.sidebarFolderPath(row: overlapping, card: card, cardRadius: 12, rowRadius: 6, feet: 8) == nil)
    }
}
