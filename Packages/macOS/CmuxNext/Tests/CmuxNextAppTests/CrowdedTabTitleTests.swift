import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence msg 19596 (26 tabs in one pane): "all here is … which is not very helpful". A crowded
/// tab's title area was a few points wide and the title layer middle-truncated it, so CoreText drew
/// the ellipsis alone. A crowded tab shows the start of its title, faded (Chrome, Helium); middle
/// truncation stays only while it keeps text on both sides of the "…".
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

    /// The width CoreText needs to draw `title` middle-truncated with `keep` characters each side.
    private func middleWidth(_ title: String, keep: Int, font: NSFont) -> CGFloat {
        let text = String(title.prefix(keep)) + "…" + String(title.suffix(keep))
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    @Test(arguments: [10, 26, 50])
    func aCrowdedTabNeverDrawsItsTitleAsAnEllipsisAlone(count: Int) {
        DesignSettings.shared.tabOverflow = .shrink
        DesignSettings.shared.setOverride(.tabMinInactiveWidth, nil)
        let harness = Harness(count: count)
        defer { harness.window.closeAfterTest() }
        for (id, cell) in harness.strip.cells where cell.visibility.showsTitle && cell.titleLayer.truncation == .middle {
            let visible = cell.titleLayer.bounds.width
            #expect(visible >= middleWidth(cell.displayTitle, keep: 2, font: cell.titleFont) - 0.5,
                    "\(id.rawValue) (\(cell.frame.width) pt) middle-truncates \"\(cell.displayTitle)\" into \(visible) pt: only \"…\" shows")
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

    @Test func middleTruncationNeedsTextOnBothSidesOfTheEllipsis() {
        #expect(TabCell.titleTruncation(textWidth: 200, visibleWidth: 120, middleMinimum: 40) == .middle)
        #expect(TabCell.titleTruncation(textWidth: 200, visibleWidth: 20, middleMinimum: 40) == nil)
        #expect(TabCell.titleTruncation(textWidth: 60, visibleWidth: 120, middleMinimum: 40) == .middle)
    }
}
