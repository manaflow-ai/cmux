import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-20: the narrowest a tab gets is the room for its favicon and its close button,
/// worked out from the parts (not a flat number), and Settings > Tabs > Minimum Tab Width still
/// overrides it. A crowded strip's tabs sit at that width; a hovered one shows its favicon and its x
/// whole, and the x's click target (Apple's 20 x 20 pt macOS minimum) never covers the favicon.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabMinimumWidthTests {
    private struct Harness {
        let window: NSWindow
        let strip: TabStripView
        let selected: TabID

        init(count: Int = 60, width: CGFloat = 1600) {
            let tabs = (0..<count).map { TabItem(id: TabID("tab\($0)"), title: "Tab number \($0) with a long title") }
            selected = TabID("tab\(count - 1)")
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: selected))
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: width, height: TabStripView.preferredHeight)
            window.contentView = strip
            settle()
        }

        func settle() {
            strip.layoutSubtreeIfNeeded()
            strip.layoutSubtreeIfNeeded()
        }

        func refresh() {
            strip.applyTokens(animated: false)
            settle()
        }
    }

    /// The slot that holds the favicon and the x side by side: both pill insets, the leading inset,
    /// the favicon, the favicon-to-x gap, the x and its trailing inset.
    private func faviconAndCloseWidth(_ m: TabStripMetrics) -> CGFloat {
        2 * m.tabBackgroundInset + m.contentLeadingInset + m.iconSize + m.titleCloseSpacing + m.closeButtonSize + m.contentTrailingInset
    }

    @Test func theDefaultMinimumIsTheFaviconPlusCloseWidth() {
        DesignSettings.shared.tabOverflow = .shrink
        DesignSettings.shared.setOverride(.tabMinInactiveWidth, nil)
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let m = harness.strip.metrics
        #expect(m.minInactiveTabWidth == faviconAndCloseWidth(m), "minimum \(m.minInactiveTabWidth), favicon + x need \(faviconAndCloseWidth(m))")
        #expect(m.faviconCloseWidth == faviconAndCloseWidth(m))
        let unselected = harness.strip.result.slots.filter { $0.id != harness.selected }.map(\.width)
        #expect(unselected.allSatisfy { $0 == m.minInactiveTabWidth }, "\(Set(unselected))")
    }

    @Test func aHoveredTabAtTheMinimumShowsItsFaviconAndItsCloseButtonWhole() throws {
        DesignSettings.shared.tabOverflow = .shrink
        DesignSettings.shared.setOverride(.tabMinInactiveWidth, nil)
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let m = harness.strip.metrics
        let cell = try #require(harness.strip.cells[TabID("tab3")])
        #expect(abs(cell.frame.width - m.minInactiveTabWidth) < 0.5, "tab3 is \(cell.frame.width) wide")
        cell.isHovered = true
        #expect(cell.visibility.showsIcon && cell.visibility.showsClose && !cell.visibility.showsTitle, "\(cell.visibility)")
        let close = try #require(cell.closeButtonRect, "a hovered tab at the minimum has no x")
        let pill = m.pillFrame(slotWidth: cell.frame.width, height: cell.frame.height)
        let icon = CGRect(x: cell.iconLayer.position.x - cell.iconLayer.bounds.width / 2, y: 0,
                          width: cell.iconLayer.bounds.width, height: cell.frame.height)
        #expect(cell.iconLayer.opacity == 1)
        #expect(icon.minX >= pill.minX && icon.width == m.iconSize, "favicon \(icon) in pill \(pill)")
        // The x's click target is the drawn button plus 2 pt a side (TabStripView.isInCloseButton): 20 pt.
        let target = close.insetBy(dx: -2, dy: -2)
        #expect(target.width >= 20, "close target \(target.width) pt, under Apple's 20 pt macOS minimum")
        #expect(target.maxX <= pill.maxX + 0.01, "close target \(target) leaves the pill \(pill)")
        #expect(target.minX >= icon.maxX - 0.01, "close target \(target) covers the favicon \(icon)")
    }

    @Test func minimumTabWidthSettingOverridesTheDefault() {
        DesignSettings.shared.tabOverflow = .shrink
        defer { DesignSettings.shared.setOverride(.tabMinInactiveWidth, nil) }
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        for value: CGFloat in [72, 36] {
            DesignSettings.shared.setOverride(.tabMinInactiveWidth, value)
            harness.refresh()
            let m = harness.strip.metrics
            #expect(m.minInactiveTabWidth == value, "set \(value), got \(m.minInactiveTabWidth)")
            let unselected = harness.strip.result.slots.filter { $0.id != harness.selected }.map(\.width)
            #expect(unselected.allSatisfy { $0 == value }, "\(Set(unselected))")
        }
    }
}
