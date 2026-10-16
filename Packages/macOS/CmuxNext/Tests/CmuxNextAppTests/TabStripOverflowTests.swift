import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxTheme
import Testing

/// Tab Overflow (cx-kp9b4) on a real strip in a window: crowded Shrink tabs stop at a minimum that keeps
/// part of the title and then scroll; Scroll keeps tabs about 140 wide and scrolls; the one-time hint at
/// a crowded Shrink strip shows once, its Use Scrolling Tabs runs, and no strip shows it again.
@MainActor @Suite(.serialized) struct TabStripOverflowTests {
    @MainActor private final class Counter { var count = 0 }

    private struct Harness {
        let window: NSWindow
        let strip: TabStripView
        let selected: TabID

        init(count: Int, width: CGFloat = 1600) {
            let tabs = (0..<count).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }
            selected = TabID("tab\(count - 1)")
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: selected))
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: width, height: TabStripView.preferredHeight)
            window.contentView = strip
            settle()
        }

        /// Showing or hiding the hint changes the tabs' viewport, which lays the strip out once more.
        func settle() {
            strip.layoutSubtreeIfNeeded()
            strip.layoutSubtreeIfNeeded()
        }

        var unselectedWidths: [CGFloat] { strip.result.slots.filter { $0.id != selected }.map(\.width) }
    }

    @Test func shrinkingTabsStopAtAReadableMinimumThenScroll() throws {
        DesignSettings.shared.tabOverflow = .shrink
        let harness = Harness(count: 40)
        defer { harness.window.orderOut(nil) }
        let metrics = harness.strip.metrics
        #expect(metrics.minInactiveTabWidth >= 72, "an unpinned tab at \(metrics.minInactiveTabWidth) pt shows only its icon")
        #expect(metrics.minActiveTabWidth >= metrics.minInactiveTabWidth)
        #expect(harness.unselectedWidths.allSatisfy { $0 == metrics.minInactiveTabWidth }, "\(Set(harness.unselectedWidths))")
        let selected = try #require(harness.strip.result.slot(harness.selected))
        #expect(selected.width == metrics.minActiveTabWidth)
        #expect(harness.strip.result.contentWidth > harness.strip.viewportWidth, "40 tabs at the minimum fit, nothing scrolls")
        let cell = try #require(harness.strip.cells[harness.selected])
        #expect(cell.frame.maxX <= harness.strip.tabsClip.bounds.maxX + 0.5, "the selected last tab is scrolled out of view")
    }

    @Test func scrollingTabsKeepAComfortableWidthAndScroll() throws {
        DesignSettings.shared.tabOverflow = .scroll
        defer { DesignSettings.shared.tabOverflow = .shrink }
        let harness = Harness(count: 20)
        defer { harness.window.orderOut(nil) }
        harness.strip.applyTokens(animated: false)
        harness.settle()
        let metrics = harness.strip.metrics
        #expect(metrics.overflow == .scroll)
        #expect(metrics.minInactiveTabWidth >= 140)
        #expect(harness.unselectedWidths.allSatisfy { $0 >= 140 }, "\(Set(harness.unselectedWidths))")
        #expect(harness.strip.result.contentWidth > harness.strip.viewportWidth, "20 tabs at 140 pt fit in 1600 pt")
        let cell = try #require(harness.strip.cells[harness.selected])
        let viewport = harness.strip.tabsClip.bounds
        #expect(cell.frame.minX >= viewport.minX - 0.5 && cell.frame.maxX <= viewport.maxX + 0.5,
                "the selected tab is at \(cell.frame.minX)...\(cell.frame.maxX), the strip shows 0...\(viewport.width)")
    }

    @Test func theMinimumWidthHintShowsOnceEver() throws {
        DesignSettings.shared.tabOverflow = .shrink
        let suite = "cmux.next.tests.overflowHint.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let used = Counter()
        TabOverflowHintView.defaults = defaults
        TabOverflowHintView.owner = nil
        DesignSettings.shared.useScrollingTabs = { used.count += 1 }
        defer {
            DesignSettings.shared.useScrollingTabs = nil
            TabOverflowHintView.defaults = .standard
            TabOverflowHintView.owner = nil
            defaults.removePersistentDomain(forName: suite)
        }

        // Not crowded: no hint.
        let roomy = Harness(count: 4)
        defer { roomy.window.orderOut(nil) }
        #expect(roomy.strip.overflowHint?.isHidden ?? true)

        let crowded = Harness(count: 40)
        defer { crowded.window.orderOut(nil) }
        let hint = try #require(crowded.strip.overflowHint)
        #expect(!hint.isHidden, "a crowded Shrink strip shows no hint")
        #expect(hint.frame.minX >= crowded.strip.tabsClip.frame.maxX, "the hint covers the tabs")
        // Its button takes the accent of the strip's scope and follows that scope's theme changes.
        let scope = ThemeScope(level: .room)
        scope.root(crowded.strip)
        for foreground: UInt32 in [0xE8D8B0, 0xB0D8E8] {
            let input = ThemeInput(background: ThemeRGB(hex: 0x101418), foreground: ThemeRGB(hex: foreground))
            scope.setOverride(try #require(ThemeSpec("Overflow Hint Room")), input: input, animated: false)
            #expect(hint.useButton.contentTintColor == scope.tokens.focusRing.nsColor, "the hint's button is not in the strip's theme")
        }
        // Only one strip shows it.
        let second = Harness(count: 40)
        defer { second.window.orderOut(nil) }
        #expect(second.strip.overflowHint?.isHidden ?? true)

        hint.useButton.performClick(nil)
        #expect(used.count == 1)
        #expect(hint.isHidden)
        #expect(defaults.bool(forKey: TabOverflowHintView.answeredKey))

        // Answered: never again, on any strip.
        let later = Harness(count: 40)
        defer { later.window.orderOut(nil) }
        #expect(later.strip.overflowHint?.isHidden ?? true)
    }
}
