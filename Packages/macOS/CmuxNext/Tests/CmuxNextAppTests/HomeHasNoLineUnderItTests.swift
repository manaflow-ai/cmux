import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-13 (msg 31467): "get rid of line under "home"". Minimal Mode draws the Lines look, which put a
/// separator (or, with `appearance.borders` none, a tonal step) between Home's section and the section under it: the
/// pinned block's leading line in the list, and the line between the two sections in a band. No line and no tonal step
/// under Home now, at every app and sidebar density; Home keeps the Lines look's section gap, so it still reads apart.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeHasNoLineUnderItTests {
    /// Home's section, then the Pinned section, then the rows: the list's blocks (the sidebar document, the app's path).
    @Test(arguments: SidebarTopRowsRhythmTests.cases)
    func theListDrawsNoLineUnderHome(_ c: SidebarTopRowsRhythmTests.Case) throws {
        try SidebarTopRowsRhythmTests.at(c) {
            let (list, window) = SidebarTopRowsRhythmTests.list(look: .lines, drawsLines: true)
            defer { window.close() }
            let home = try SidebarTopRowsRhythmTests.item(list, SidebarTopRowsRhythmTests.home.id)
            let pins = try SidebarTopRowsRhythmTests.pins.map { try SidebarTopRowsRhythmTests.item(list, $0.id) }
            let homeFill = SidebarTopRowsRhythmTests.fill(list, home)
            let pinFills = pins.map { SidebarTopRowsRhythmTests.fill(list, $0) }
            let firstPin = try #require(pinFills.first)
            for region in list.blockRegions {
                for line in region.layoutResult.separators {
                    let frame = list.convert(line, from: region)
                    #expect(!Self.between(frame, homeFill, firstPin, flipped: list.isFlipped),
                            "\(c.testDescription): a line at \(frame) under Home (\(homeFill)), over the first pin (\(firstPin))")
                }
            }
            // Home still reads apart: more room under it than between two pins.
            let homeStep = abs(firstPin.midY - homeFill.midY), pinStep = abs(pinFills[1].midY - firstPin.midY)
            #expect(homeStep > pinStep + SidebarTopRowsRhythmTests.tolerance,
                    "\(c.testDescription): Home to the first pin steps \(homeStep) pt, pin to pin \(pinStep) pt")
        }
    }

    /// Home's and the Pinned section in one band (the older resolver, with no sidebar document): no line and no
    /// tonal step between them.
    @Test(arguments: [true, false])
    func aBandDrawsNoLineOrToneUnderHome(drawsLines: Bool) throws {
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list,
                                items: [SidebarTopRowsRhythmTests.home])
        let pinned = SidebarLayoutDocument.pinnedSection(items: SidebarTopRowsRhythmTests.pins)
        var infos: [LayoutItemID: SidebarItemInfo] = [SidebarTopRowsRhythmTests.home.id: .fallback(for: SidebarTopRowsRhythmTests.home)]
        for pin in SidebarTopRowsRhythmTests.pins { infos[pin.id] = SidebarItemInfo(title: pin.id.rawValue, symbol: "textformat") }
        let content = SidebarRegionView.Content(sections: [top, pinned], infos: infos, collapsed: [], look: .lines,
                                                metrics: .standard, drawsLines: drawsLines, appHeights: [:])
        let layout = SidebarRegionView.layout(of: content, width: 260)
        let homeFrame = try #require(layout.sectionFrames.first, "Home's section laid out nothing")
        let pinnedFrame = try #require(layout.sectionFrames.dropFirst().first, "the Pinned section laid out nothing")
        for line in SidebarRegionView.lineFrames(of: layout, look: .lines, drawsLines: drawsLines) {
            #expect(!Self.between(line.frame, homeFrame, pinnedFrame, flipped: true) && line.frame != pinnedFrame,
                    "drawsLines \(drawsLines): \(line.key) at \(line.frame) under Home (\(homeFrame)) over the pins (\(pinnedFrame))")
        }
        #expect(pinnedFrame.minY - homeFrame.maxY >= SidebarRegionMetrics.standard.sectionGap - 0.5,
                "Home lost the section gap under it")
    }

    /// Whether `line` sits in the room between `above` and `below` (it touches neither row's middle).
    static func between(_ line: CGRect, _ above: CGRect, _ below: CGRect, flipped: Bool) -> Bool {
        let (top, bottom) = flipped ? (above.midY, below.midY) : (below.midY, above.midY)
        return line.midY > min(top, bottom) && line.midY < max(top, bottom)
    }
}
