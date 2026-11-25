import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// The tab strip follows the density's browser rows (Lawrence 2026-11-13, density thread, 4012bb9f9c935b): at Compact,
/// the density these tests run at, Default's design scaled by 0.9 on 28 pt rows, a 33 pt strip, and a 6.5 pt title gap.
/// The Compact tabs option (cx-ag5.12, Leo 2026-10-12; off by default) is
/// tighter still and never taller: its icon sits closer to its title, and its close and + buttons keep their targets.
@MainActor @Suite(.serialized, .closesItsWindows) struct CompactTabStripTests {
    @Test func theDefaultStripFollowsTheDensitysBrowserRows() throws {
        let (strip, window) = Self.strip()
        defer { window.closeAfterTest() }
        let cell = try #require(strip.cells[TabID("tab1")])
        #expect(Metrics.chromeRowHeight == 28, "Compact's browser row is \(Metrics.chromeRowHeight) pt")
        #expect(cell.frame.height == Metrics.chromeRowHeight, "a tab is \(cell.frame.height) pt")
        #expect(strip.bounds.height == 33, "the strip is \(strip.bounds.height) pt: the row and 2.5 pt above and under it")
        #expect(strip.metrics.contentLeadingInset == 7.5)
        #expect(strip.metrics.iconTitleSpacing == 6.5, "the title sits \(strip.metrics.iconTitleSpacing) pt after the icon")
    }

    static func strip() -> (TabStripView, NSWindow) {
        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = strip
        // Mouse events reach the strip only in a window that was ordered in.
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        return (strip, window)
    }

    @Test func compactTabsAreTighterNeverTallerAndTheirButtonsStillTakeAClick() async throws {
        let (plain, plainWindow) = Self.strip()
        let plainTab = try #require(plain.cells[TabID("tab1")]).frame.height
        let plainStrip = plain.bounds.height
        let plainInset = plain.metrics.contentLeadingInset
        plainWindow.closeAfterTest()

        let key = ChromeTunables.compactTabs.descriptor.key
        // Debug Settings overrides apply once the store is active; no file, so nothing is written.
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([ChromeTunables.compactTabs.descriptor])
        try #require(TunableStore.shared.set(key, .bool(true)) == .bool(true), "the toggle takes the override")
        defer { TunableStore.shared.set(key, nil) }
        let (strip, window) = Self.strip()
        defer { window.closeAfterTest() }
        var intents: [TabStripIntent] = []
        strip.model.intentHandler = { intents.append($0) }

        let cell = try #require(strip.cells[TabID("tab1")])
        #expect(cell.frame.height <= plainTab, "Compact tabs draw a \(cell.frame.height) pt tab, taller than the \(plainTab) pt default")
        #expect(strip.bounds.height <= plainStrip, "Compact tabs draw a \(strip.bounds.height) pt strip, taller than the \(plainStrip) pt default")
        #expect(cell.frame.height <= Metrics.sidebarRowHeight, "a tab (\(cell.frame.height) pt) is taller than a sidebar row")
        #expect(strip.metrics.iconTitleSpacing == Metrics.space2, "the title sits \(strip.metrics.iconTitleSpacing) pt after the icon")
        #expect(strip.metrics.iconTitleSpacing < plain.metrics.iconTitleSpacing)
        #expect(strip.metrics.contentLeadingInset <= plainInset, "a tab's icon sits \(strip.metrics.contentLeadingInset) pt in")

        // The close button keeps Apple's 20 x 20 pt target (Helium's 14 pt square drawn) and closes the tab.
        let center = strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip)
        TabStripDebug.pointerMoved(in: strip, to: center)
        let close = try #require(cell.closeButtonRect, "the hovered tab shows no close button")
        let target = strip.metrics.closeHitRect(close)
        #expect(target.width >= 20 && target.height >= 20, "the close button's target is \(target.size)")
        click(strip.convert(strip.convert(CGPoint(x: cell.frame.minX + close.midX, y: cell.frame.minY + close.midY), from: strip.tabsClip), to: nil), in: window)
        #expect(intents.contains { if case .close(TabID("tab1"), _) = $0 { true } else { false } }, "\(intents)")

        // The + keeps its width and opens a tab; it is the pane ⋮'s height in every look (Lawrence 2026-11-20).
        let plus = strip.convert(strip.newTabButton.frame, from: strip.contentView)
        #expect(plus.width == strip.metrics.newTabButtonWidth, "the + is \(plus.size)")
        #expect(plus.height == NewTabButtonView.frameHeight, "the + is \(plus.size)")
        click(strip.convert(CGPoint(x: plus.midX, y: plus.midY), to: nil), in: window)
        #expect(intents.contains { if case .newTab = $0 { true } else { false } }, "\(intents)")
    }

    private func click(_ point: CGPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { continue }
            window.sendEvent(event)
        }
    }
}
