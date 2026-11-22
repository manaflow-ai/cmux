import AppKit
import Testing
@testable import CmuxNextTabs

/// The agent cursor's hidden-tab indicator points at a tab's chip, also when
/// the strip has scrolled the chip out of its tab area (CURSOR-HIDDEN).
@MainActor @Suite struct TabChipAnchorTests {
    private func strip(tabs count: Int, width: CGFloat) -> (TabStripView, NSWindow) {
        let tabs = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("t0")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        strip.frame = NSRect(x: 0, y: 0, width: width, height: TabStripView.preferredHeight)
        window.contentView?.addSubview(strip)
        strip.sync(fromModel: true)
        strip.layoutSubtreeIfNeeded()
        return (strip, window)
    }

    @Test func aShownChipAnswersItsOwnFrame() throws {
        let (strip, window) = strip(tabs: 3, width: 900)
        defer { window.close() }
        let first = try #require(TabChipAnchor.rect(of: TabID("t0"), in: strip))
        let second = try #require(TabChipAnchor.rect(of: TabID("t1"), in: strip))
        #expect(first.width > 0 && first.height > 0)
        #expect(second.minX > first.minX)
        #expect(strip.bounds.contains(first) && strip.bounds.contains(second))
    }

    @Test func aChipScrolledOutIsPinnedToTheTabAreaEdge() throws {
        let (strip, window) = strip(tabs: 60, width: 320)
        defer { window.close() }
        let area = strip.tabsClip.convert(strip.tabsClip.bounds, to: strip)
        let last = try #require(TabChipAnchor.rect(of: TabID("t59"), in: strip))
        #expect(abs(last.maxX - area.maxX) < 0.5, "last chip \(last) area \(area)")
        #expect(last.minX >= area.minX - 0.5)
    }

    @Test func anUnknownTabHasNoChip() {
        let (strip, window) = strip(tabs: 2, width: 600)
        defer { window.close() }
        #expect(TabChipAnchor.rect(of: TabID("missing"), in: strip) == nil)
    }

    @Test func clampingKeepsTheChipSizeInsideTheArea() {
        let area = CGRect(x: 0, y: 0, width: 300, height: 30)
        #expect(TabChipAnchor.clamped(CGRect(x: 500, y: 2, width: 100, height: 26), into: area) == CGRect(x: 200, y: 2, width: 100, height: 26))
        #expect(TabChipAnchor.clamped(CGRect(x: -400, y: 2, width: 100, height: 26), into: area) == CGRect(x: 0, y: 2, width: 100, height: 26))
        #expect(TabChipAnchor.clamped(CGRect(x: 40, y: 2, width: 100, height: 26), into: area) == CGRect(x: 40, y: 2, width: 100, height: 26))
    }
}
