import AppKit
import CmuxNextInput
@testable import CmuxNextTabs
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Tab strip hover once per frame (feature `pointerFrameHover`, p04-input-033): with the window's
/// frame-aligned input, a frame's pointer moves hit-test the tabs once, at the latest point, as
/// Chromium delivers rAF-aligned moves (main_thread_event_queue.cc). Enter, exit and a press land
/// the pending moves first, so a click after fast moves selects the tab under its own point.
@MainActor @Suite(.serialized) struct TabStripPointerTests {
    @MainActor final class Harness {
        let model: TabStripModel
        let strip: TabStripView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        let scheduler: FrameScheduler
        let coalescer: FrameInputCoalescer
        /// Every hovered tab the strip reported, in order (`onHoverTab`: one call per hover change).
        var hoverChanges: [TabID?] = []

        init(frameInput: Bool = true) {
            _ = NSApplication.shared
            model = TabStripModel(tabs: (0..<6).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }, selectedID: TabID("t0"))
            strip = TabStripView(model: model, input: InputEventTap())
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
            window.isReleasedWhenClosed = false
            window.contentView = strip
            strip.layoutSubtreeIfNeeded()
            scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in TabStripPointerFakeLink() }
            let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
            self.coalescer = coalescer
            if frameInput { strip.hoverFrameInput = FrameInputCoalescers(make: { _ in coalescer }) }
            model.intentHandler = { [unowned self] intent in
                if case .select(let id) = intent { model.selectedID = id }
            }
            strip.onHoverTab = { [unowned self] id in hoverChanges.append(id) }
        }

        /// A point inside tab `index`, away from its close button, in window coordinates.
        func point(_ index: Int) throws -> CGPoint {
            let cell = try #require(strip.cells[TabID("t\(index)")], "no cell for t\(index)")
            return strip.convert(strip.convert(CGPoint(x: cell.frame.minX + 12, y: cell.frame.midY), from: strip.tabsClip), to: nil)
        }

        func event(_ type: NSEvent.EventType, tab index: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: try point(index), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        func move(to index: Int) throws { strip.mouseMoved(with: try event(.mouseMoved, tab: index)) }

        func frame() { scheduler.frameDidFire(timestamp: 1000, refreshInterval: 1.0 / 120) }

        func exit(at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }

        func close() {
            coalescer.invalidate()
            window.close()
        }
    }

    /// Eight moves across the strip in one frame hover once, the tab under the last move; nothing
    /// hovers before the frame comes.
    @Test func eightMovesInOneFrameHoverOnceAtTheLatestTab() throws {
        let harness = Harness()
        defer { harness.close() }
        for step in 0..<8 { try harness.move(to: step % 6) }
        #expect(harness.hoverChanges.count <= 2, "the moves hovered \(harness.hoverChanges.count) tabs before the frame")
        #expect(harness.coalescer.hasPending)
        harness.frame()
        #expect(harness.hoverChanges.count >= 1 && harness.hoverChanges.count <= 2, "the frame hovered \(harness.hoverChanges)")
        #expect(harness.strip.hoveredID == TabID("t\(7 % 6)"))
        #expect(!harness.coalescer.hasPending)
    }

    /// A press after fast moves (none delivered yet) selects the tab under the press, and no move of
    /// the frame before it is left for a later frame to hover.
    @Test func aClickAfterFastMovesSelectsTheTabUnderTheClick() throws {
        let harness = Harness()
        defer { harness.close() }
        try harness.move(to: 1)
        harness.frame()
        #expect(harness.strip.hoveredID == TabID("t1"))
        for index in [2, 3, 4] { try harness.move(to: index) }
        harness.strip.mouseDown(with: try harness.event(.leftMouseDown, tab: 4))
        #expect(!harness.coalescer.hasPending, "the press left moves for a later frame")
        #expect(harness.strip.hoveredID == TabID("t4"), "the press saw a stale hover")
        harness.strip.mouseUp(with: try harness.event(.leftMouseUp, tab: 4))
        #expect(harness.model.selectedID == TabID("t4"))
    }

    /// Leaving the strip lands the pending moves before it clears the hover: a frame after the exit
    /// lights no tab.
    @Test func anExitFlushesThePendingMovesThenClearsTheHover() throws {
        let harness = Harness()
        defer { harness.close() }
        try harness.move(to: 2)
        try harness.move(to: 3)
        harness.strip.mouseExited(with: try harness.exit(at: try harness.point(3)))
        #expect(!harness.coalescer.hasPending)
        #expect(harness.strip.hoveredID == nil)
        harness.frame()
        #expect(harness.strip.hoveredID == nil, "a move delivered after the exit lit a tab")
    }

    /// With the feature off (no frame-aligned input), every move hovers at once.
    @Test func withoutFrameInputEveryMoveHovers() throws {
        let harness = Harness(frameInput: false)
        defer { harness.close() }
        for index in 0..<4 { try harness.move(to: index) }
        #expect(harness.hoverChanges == (0..<4).map { Optional(TabID("t\($0)")) })
        #expect(!harness.coalescer.hasPending)
    }
}

@MainActor
private final class TabStripPointerFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
