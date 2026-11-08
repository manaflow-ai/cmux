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

        init(count: Int, width: CGFloat = 1116) {
            let titles = ["cmux-next", "feat-cmux-next", "Helper 1", "Helper 2", "zsh", "claude", "npm run dev"]
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

    @Test func noTitleIsEverTruncated() {
        #expect(TabCell.titleTruncation(textWidth: 200, visibleWidth: 120) == nil)
        #expect(TabCell.titleTruncation(textWidth: 200, visibleWidth: 20) == nil)
        #expect(TabCell.titleTruncation(textWidth: 60, visibleWidth: 120) == nil)
    }
}
