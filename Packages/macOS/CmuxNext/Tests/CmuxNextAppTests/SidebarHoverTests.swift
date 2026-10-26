import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Sidebar hover once per frame (feature `pointerFrameHover`, p04-input-033): with the window's
/// frame-aligned input, a frame's pointer moves hit-test the rows once, at the latest point, as
/// Chromium delivers rAF-aligned moves (main_thread_event_queue.cc). Enter, exit and a press are
/// discrete: they land the pending moves first, so a click after fast moves acts on the row under
/// its own point.
@MainActor @Suite(.serialized) struct SidebarHoverTests {
    @MainActor final class Harness {
        let list: SidebarListView
        let window: NSWindow
        let scheduler: FrameScheduler
        let coalescer: FrameInputCoalescer
        let rows: [SidebarRow]
        /// Every hovered row the list showed, in order (one entry per hover change).
        var hoverChanges: [SidebarRowKey?] = []
        private var lastHovered: SidebarRowKey?

        init(frameInput: Bool = true) throws {
            _ = NSApplication.shared
            let titles = ["one", "two", "three", "four", "five", "six"]
            let workspaces = titles.enumerated().map { SidebarWorkspace(id: WorkspaceID("ws-\($0.offset)"), title: $0.element) }
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })],
                                     activeWorkspaceID: WorkspaceID("ws-0"))
            list = SidebarListView(model: model)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = list
            list.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
            list.reload(animated: false)
            rows = list.displayed.rows.filter { if case .workspace = $0.key { true } else { false } }
            scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in SidebarHoverFakeLink() }
            let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
            self.coalescer = coalescer
            if frameInput { list.hoverFrameInput = FrameInputCoalescers(make: { _ in coalescer }) }
            try #require(rows.count == titles.count)
        }

        /// The window point in the middle of row `index`.
        func point(_ index: Int) -> NSPoint {
            let row = rows[index]
            return list.convert(NSPoint(x: list.bounds.midX, y: row.y + row.height / 2), to: nil)
        }

        func event(_ type: NSEvent.EventType, row index: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point(index), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        func move(to index: Int) throws {
            list.mouseMoved(with: try event(.mouseMoved, row: index))
            record()
        }

        func frame() {
            scheduler.frameDidFire(timestamp: 1000, refreshInterval: 1.0 / 120)
            record()
        }

        func record() {
            guard list.hoveredKey != lastHovered else { return }
            lastHovered = list.hoveredKey
            hoverChanges.append(lastHovered)
        }

        func exit(at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }

        func close() {
            coalescer.invalidate()
            window.close()
        }
    }

    /// Eight moves down the list in one frame hover once, the row under the last move; nothing hovers
    /// before the frame comes.
    @Test func eightMovesInOneFrameHoverOnceAtTheLatestRow() throws {
        let harness = try Harness()
        defer { harness.close() }
        for step in 0..<8 { try harness.move(to: step % harness.rows.count) }
        #expect(harness.hoverChanges.count <= 2, "the moves hovered \(harness.hoverChanges.count) rows before the frame")
        #expect(harness.coalescer.hasPending)
        harness.frame()
        #expect(harness.hoverChanges.count >= 1 && harness.hoverChanges.count <= 2, "the frame hovered \(harness.hoverChanges)")
        #expect(harness.list.hoveredKey == harness.rows[7 % harness.rows.count].key)
        #expect(!harness.coalescer.hasPending)
    }

    /// A press after fast moves (none delivered yet) acts on the row under the press: the pending moves
    /// land first, and the hover the press reads is the row it is on, not a stale one.
    @Test func aClickAfterFastMovesHitsTheRowUnderTheClick() throws {
        let harness = try Harness()
        defer { harness.close() }
        try harness.move(to: 1)
        harness.frame()
        #expect(harness.list.hoveredKey == harness.rows[1].key)
        for index in [2, 3, 4] { try harness.move(to: index) }
        harness.list.mouseDown(with: try harness.event(.leftMouseDown, row: 4))
        harness.list.mouseUp(with: try harness.event(.leftMouseUp, row: 4))
        #expect(!harness.coalescer.hasPending, "the press left moves for a later frame")
        #expect(harness.list.model.selection == [WorkspaceID("ws-4")])
    }

    /// Leaving the list lands the pending moves before it clears the hover: a frame that comes after the
    /// exit lights no row.
    @Test func anExitFlushesThePendingMovesThenClearsTheHover() throws {
        let harness = try Harness()
        defer { harness.close() }
        try harness.move(to: 2)
        try harness.move(to: 3)
        harness.list.mouseExited(with: try harness.exit(at: harness.point(3)))
        #expect(!harness.coalescer.hasPending)
        #expect(harness.list.hoveredKey == nil)
        harness.frame()
        #expect(harness.list.hoveredKey == nil, "a move delivered after the exit lit a row")
    }

    /// With the feature off (no frame-aligned input), every move hovers at once.
    @Test func withoutFrameInputEveryMoveHovers() throws {
        let harness = try Harness(frameInput: false)
        defer { harness.close() }
        for index in 0..<4 { try harness.move(to: index) }
        #expect(harness.hoverChanges == (0..<4).map { Optional(harness.rows[$0].key) })
        #expect(!harness.coalescer.hasPending)
    }
}

@MainActor
private final class SidebarHoverFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
