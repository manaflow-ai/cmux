import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence msg 20243: the pinned icon-only tabs sat against the first normal tab, with a gap that
/// matched nothing else in the strip. The pinned group ends in one subtle divider, and the space on
/// each side of it is the space between any two tabs.
@MainActor @Suite(.serialized, .closesItsWindows) struct PinnedTabGroupGapTests {
    private struct Harness {
        let window: NSWindow
        let strip: TabStripView

        init(pinned: Int, unpinned: Int, selected: Int) {
            var tabs: [TabItem] = []
            for index in 0..<pinned { tabs.append(TabItem(id: TabID("pin\(index)"), title: "Doc \(index)", icon: .symbol("doc"), isPinned: true)) }
            for index in 0..<unpinned { tabs.append(TabItem(id: TabID("tab\(index)"), title: "cmux-next \(index)")) }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: tabs[selected].id))
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
            window.contentView = strip
            strip.layoutSubtreeIfNeeded()
            strip.layoutSubtreeIfNeeded()
        }

        /// A tab's pill (its rounded background) in the strip's coordinates.
        func pill(_ id: String) throws -> CGRect {
            let cell = try #require(strip.cells[TabID(id)])
            return cell.layer.convert(cell.pillFrameInCell, to: strip.layer)
        }

        /// The pinned group's divider in the strip's coordinates, nil when the strip draws none.
        func divider() -> CGRect? {
            let line = strip.pinnedDivider
            guard line.name == TabStripView.pinnedDividerName, !line.isHidden, line.opacity > 0, line.bounds.height > 0,
                  let parent = line.superlayer else { return nil }
            return parent.convert(line.frame, to: strip.layer)
        }
    }

    /// The first normal tab selected, as in the shot: the divider still shows, and the space on each
    /// side of it is the space between two tabs.
    @Test(arguments: [false, true])
    func thePinnedGroupEndsInADividerWithTheTabGapOnEachSide(firstNormalSelected: Bool) throws {
        DesignSettings.shared.tabOverflow = .shrink
        let harness = Harness(pinned: 2, unpinned: 4, selected: firstNormalSelected ? 2 : 4)
        defer { harness.window.closeAfterTest() }
        let tabGap = try harness.pill("tab2").minX - harness.pill("tab1").maxX
        let pinnedGap = try harness.pill("pin1").minX - harness.pill("pin0").maxX
        #expect(abs(pinnedGap - tabGap) < 0.5, "pinned tabs \(pinnedGap) pt apart, normal tabs \(tabGap) pt")
        let line = harness.strip.pinnedDivider
        let divider = try #require(harness.divider(), """
            no divider between the pinned tabs and the first normal tab: hidden \(line.isHidden), opacity \(line.opacity), \
            frame \(line.frame), in a layer \(line.superlayer != nil), on \(harness.strip.metrics.showsPinnedDivider)
            """)
        let before = divider.minX - (try harness.pill("pin1").maxX)
        let after = (try harness.pill("tab0").minX) - divider.maxX
        #expect(abs(before - tabGap) < 0.5, "last pinned tab to divider \(before) pt, between tabs \(tabGap) pt")
        #expect(abs(after - tabGap) < 0.5, "divider to first normal tab \(after) pt, between tabs \(tabGap) pt")
        #expect(divider.width <= 1.01, "divider \(divider.width) pt wide: a hairline")
        #expect(divider.height < harness.strip.metrics.tabHeight, "divider \(divider.height) pt: shorter than a tab")
    }

    @Test func aStripWithoutBothGroupsDrawsNoDivider() {
        DesignSettings.shared.tabOverflow = .shrink
        let onlyNormal = Harness(pinned: 0, unpinned: 4, selected: 0)
        defer { onlyNormal.window.closeAfterTest() }
        #expect(onlyNormal.divider() == nil)
        let onlyPinned = Harness(pinned: 3, unpinned: 0, selected: 0)
        defer { onlyPinned.window.closeAfterTest() }
        #expect(onlyPinned.divider() == nil)
    }
}
