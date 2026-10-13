import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Leo 2026-10-12 (cx-ag5.12): the tab strip at its default density is compact.
/// A tab is shorter than a sidebar row and starts closer to its icon, and the
/// strip around it is no taller than a sidebar row and one grid step. The
/// close and + buttons keep their size, and both still take a click.
@MainActor @Suite(.serialized) struct CompactTabStripTests {
    @Test func theDefaultStripIsCompactAndItsButtonsKeepTheirSize() async throws {
        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
        var intents: [TabStripIntent] = []
        model.intentHandler = { intents.append($0) }
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = strip
        // Mouse events reach the strip only in a window that was ordered in.
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        strip.layoutSubtreeIfNeeded()

        let row = Metrics.sidebarRowHeight
        let cell = try #require(strip.cells[TabID("tab1")])
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
