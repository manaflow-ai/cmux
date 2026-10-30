import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Familiar first (Lawrence 2026-10-14): the default tab strip keeps the size people know, a
/// 28 pt strip with 24 pt tabs, the icon 8 pt in and 6 pt from the title. The tighter strip of
/// cx-ag5.12 (Leo 2026-10-12) is the Compact tabs toggle, off by default; there a tab is shorter
/// than a sidebar row and starts closer to its icon, and the close and + buttons keep their size
/// and still take a click.
@MainActor @Suite(.serialized, .closesItsWindows) struct CompactTabStripTests {
    @Test func theDefaultStripKeepsItsFamiliarSize() throws {
        let (strip, window) = Self.strip()
        defer { window.closeAfterTest() }
        let cell = try #require(strip.cells[TabID("tab1")])
        #expect(strip.bounds.height == 28, "the strip is \(strip.bounds.height) pt")
        #expect(cell.frame.height == 24, "a tab is \(cell.frame.height) pt")
        #expect(strip.metrics.contentLeadingInset == 8, "a tab's icon sits \(strip.metrics.contentLeadingInset) pt in")
        #expect(strip.metrics.iconTitleSpacing == 6, "the title sits \(strip.metrics.iconTitleSpacing) pt after the icon")
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

    @Test func compactTabsAreTighterAndTheirButtonsKeepTheirSize() async throws {
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

        let row = Metrics.sidebarRowHeight
        let cell = try #require(strip.cells[TabID("tab1")])
        #expect(strip.bounds.height == 26 && cell.frame.height == 22, "the strip is \(strip.bounds.height) pt, a tab \(cell.frame.height) pt")
        #expect(strip.metrics.iconTitleSpacing == 4, "the title sits \(strip.metrics.iconTitleSpacing) pt after the icon")
        #expect(cell.frame.height < row, "a tab (\(cell.frame.height) pt) is as tall as a sidebar row (\(row) pt)")
        #expect(strip.bounds.height <= row + Metrics.space1, "the strip (\(strip.bounds.height) pt) is taller than a sidebar row and a grid step")
        #expect(strip.metrics.contentLeadingInset < Metrics.space4, "a tab's icon sits \(strip.metrics.contentLeadingInset) pt in")

        // The close button keeps its size and closes the tab.
        let center = strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip)
        TabStripDebug.pointerMoved(in: strip, to: center)
        let close = try #require(cell.closeButtonRect, "the hovered tab shows no close button")
        #expect(close.width == Metrics.space6 && close.height == Metrics.space6, "the close button is \(close.size)")
        click(strip.convert(strip.convert(CGPoint(x: cell.frame.minX + close.midX, y: cell.frame.minY + close.midY), from: strip.tabsClip), to: nil), in: window)
        #expect(intents.contains { if case .close(TabID("tab1"), _) = $0 { true } else { false } }, "\(intents)")

        // The + keeps its size and opens a tab.
        let plus = strip.convert(strip.newTabButton.frame, from: strip.contentView)
        #expect(plus.width == Metrics.space6 + Metrics.space4 && plus.height == Metrics.space6 + Metrics.space4, "the + is \(plus.size)")
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
