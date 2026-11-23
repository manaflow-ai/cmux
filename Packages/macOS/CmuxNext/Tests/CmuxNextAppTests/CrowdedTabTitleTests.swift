import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence msg 19596 (26 tabs in one pane): "all here is … which is not very helpful". A crowded
/// tab's title area was a few points wide and the title layer middle-truncated it, so CoreText drew
/// the ellipsis alone. A tab shows the start of its title, faded at its end (Chrome, Helium); since
/// 2026-11-07 never a "…" at all (Lawrence, beside Chrome: "Austin's…(7 days)").
@MainActor @Suite(.serialized, .closesItsWindows) struct CrowdedTabTitleTests {
    private struct Harness {
        let window: NSWindow
        let strip: TabStripView

        init(count: Int, width: CGFloat = 1116,
             titles: [String] = ["cmux-next", "feat-cmux-next", "Helper 1", "Helper 2", "zsh", "claude", "npm run dev"]) {
            let tabs = (0..<count).map { TabItem(id: TabID("tab\($0)"), title: titles[$0 % titles.count]) }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("tab0")))
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: width, height: TabStripView.preferredHeight)
            window.contentView = strip
            strip.layoutSubtreeIfNeeded()
            strip.layoutSubtreeIfNeeded()
        }
    }

    @Test(arguments: [10, 26, 50])
    func aCrowdedTabNeverDrawsAnEllipsis(count: Int) {
        DesignSettings.shared.tabOverflow = .shrink
        DesignSettings.shared.setOverride(.tabMinInactiveWidth, nil)
        let harness = Harness(count: count)
        defer { harness.window.closeAfterTest() }
        for (id, cell) in harness.strip.cells where cell.visibility.showsTitle {
            #expect(cell.titleLayer.truncation == nil, "\(id.rawValue) (\(cell.frame.width) pt) truncates \"\(cell.displayTitle)\" with a …")
        }
    }

    @Test func aCrowdedTabShowsAFewCharactersOfItsTitle() throws {
        DesignSettings.shared.tabOverflow = .shrink
        DesignSettings.shared.setOverride(.tabMinInactiveWidth, nil)
        let harness = Harness(count: 26)
        defer { harness.window.closeAfterTest() }
        let cell = try #require(harness.strip.cells[TabID("tab3")])
        #expect(cell.visibility.showsTitle, "a crowded tab at \(cell.frame.width) pt shows no title")
        let fourCharacters = ceil(("Help" as NSString).size(withAttributes: [.font: cell.titleFont]).width)
        #expect(cell.titleLayer.bounds.width >= fourCharacters, "title area \(cell.titleLayer.bounds.width) pt < four characters \(fourCharacters) pt")
    }

    /// Leo 2026-11-23 ("the end bit the text has a weird rewritten thing"): a crowded "New Tab" read "New" and a
    /// faint tick, the left end of the T's crossbar under the end of the fade. At every crowded width, no tab's fade
    /// ends inside the T: the title ends on "New" (or shows the T whole).
    @Test func aCrowdedNewTabNeverShowsAFragmentOfItsT() throws {
        DesignSettings.shared.tabOverflow = .shrink
        DesignSettings.shared.setOverride(.tabMinInactiveWidth, nil)
        // From roomy to crowded: every tab width between (Leo's strip: about 77 pt tabs).
        var cutInsideT = 0
        for count in 8...30 {
            let harness = Harness(count: count, titles: ["New Tab"])
            defer { harness.window.closeAfterTest() }
            for (id, cell) in harness.strip.cells where cell.visibility.showsTitle {
                let t = try #require(cell.titleLayer.wordStarts.first, "\"New Tab\" has no word after its space")
                guard let geometry = cell.titleFade.geometry, geometry.isTruncated else { continue }
                if geometry.clearEdge > t.x + 0.01, geometry.clearEdge < t.firstGlyphEnd - 0.01 { cutInsideT += 1 }
                #expect(!(geometry.fadeEnd > t.x + 0.01 && geometry.fadeEnd < t.firstGlyphEnd - 0.01),
                        "\(count) tabs, \(id.rawValue) (\(cell.frame.width) pt): the fade ends at \(geometry.fadeEnd), inside the T (\(t.x)–\(t.firstGlyphEnd))")
                #expect(geometry.wordStarts == cell.titleLayer.wordStarts, "\(id.rawValue) lays its fade out without its word starts")
            }
        }
        #expect(cutInsideT > 0, "SETUP: no tab width put the clear edge inside the T, so this proves nothing")
    }

    /// A title that appears while its tab opens shows once, as it rests: never at the widths in between, where
    /// the fade swept across its letters as the tab grew (Leo 2026-11-23, "the animations are weird").
    @Test func anOpeningTabsTitleShowsOnceAsItRests() {
        func sample(_ visible: CGFloat) -> TitleFade.Sample {
            TitleFade.Sample(geometry: TitleFadeGeometry(textWidth: 46, span: visible, visibleWidth: visible, leadingPadding: 6,
                                                         trailingPadding: 0, fadeWidth: 20),
                             frame: CGRect(x: 30, y: 0, width: visible, height: 16))
        }
        let opening: [TitleFade.Sample?] = [nil, nil, sample(8), sample(16), sample(24), sample(28), sample(28)]
        let shown = TabCell.titlesShownOnce(opening).map { $0 != nil }
        #expect(shown == [false, false, false, false, false, true, true])
        // Shown at the start (a neighbour making room, a close): it follows the width as before.
        let shrinking: [TitleFade.Sample?] = [sample(40), sample(28), sample(16), nil]
        #expect(TabCell.titlesShownOnce(shrinking) == shrinking)
        // A title that ends unclipped shows once it fits.
        let growing: [TitleFade.Sample?] = [nil, sample(20), sample(40), sample(60)]
        #expect(TabCell.titlesShownOnce(growing).map { $0 != nil } == [false, false, false, true])
    }

    @Test func noTitleIsEverTruncated() {
        #expect(TabCell.titleTruncation(textWidth: 200, visibleWidth: 120) == nil)
        #expect(TabCell.titleTruncation(textWidth: 200, visibleWidth: 20) == nil)
        #expect(TabCell.titleTruncation(textWidth: 60, visibleWidth: 120) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderCrowdedTabGallery() throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "crowded-tab-title-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let mixed = ["127.0.0.1:8080 / a very long browser title", "Agent session — long working title", "New Tab",
                     "Helper 1", "npm run dev -- --port 5173 --host", "New Tab"]
        // Leo's strip (2026-11-23): every tab "New Tab", crowded; and long titles beside it, in both looks.
        let sets: [(String, [String])] = [("mixed", mixed), ("newtab", ["New Tab"])]
        let looks: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]
        let widths: [(String, CGFloat)] = [("narrow", 360), ("medium", 520), ("wide", 760)]
        for (set, titles) in sets {
            for (look, appearance) in looks {
                for (size, width) in widths {
                    try renderCrowdedStrip(titles: titles, appearance: appearance, width: width, to: out, name: "\(set)-\(look)-\(size)")
                }
            }
        }
    }

    /// 26 tabs of `titles` (the first selected), then three "New Tab" opened and selected one after another.
    private func renderCrowdedStrip(titles: [String], appearance: NSAppearance.Name, width: CGFloat, to out: URL, name: String) throws {
        let tabs = (0..<26).map { TabItem(id: TabID("tab\($0)"), title: titles[$0 % titles.count]) }
        let model = TabStripModel(tabs: tabs, selectedID: tabs[0].id)
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.close() }
        window.appearance = NSAppearance(named: appearance)
        window.contentView = strip
        strip.frame = NSRect(x: 0, y: 0, width: width, height: TabStripView.preferredHeight)
        strip.layoutSubtreeIfNeeded()
        strip.layoutSubtreeIfNeeded()
        let rep = try #require(strip.bitmapImageRepForCachingDisplay(in: strip.bounds))
        strip.cacheDisplay(in: strip.bounds, to: rep)
        try AAGroupHeaderDensityGalleryTests.write(try #require(rep.cgImage), to: out.appending(path: "\(name)-many.png"))

        for index in 26..<29 {
            let id = TabID("rapid-\(index)")
            model.tabs.append(TabItem(id: id, title: "New Tab"))
            model.selectedID = id
            strip.sync(fromModel: true, animating: false)
        }
        strip.layoutSubtreeIfNeeded()
        let rapid = try #require(strip.bitmapImageRepForCachingDisplay(in: strip.bounds))
        strip.cacheDisplay(in: strip.bounds, to: rapid)
        try AAGroupHeaderDensityGalleryTests.write(try #require(rapid.cgImage), to: out.appending(path: "\(name)-rapid.png"))
    }
}
