import AppKit
import CmuxNextBridge
import struct CmuxNextDaemon.CellSize
import Testing

/// A drag's grids go as steps of one live resize; when the window stops resizing live, each
/// terminal's last grid goes once more, settled, which ends the live resize at the daemon, so its
/// byte mirrors are rebuilt once, at the final grid (H10, live-resize-v1; Chrome coalesces resize
/// to the frame and settles at the end).
@MainActor
@Suite struct ResizeCoordinatorLiveResizeTests {
    final class Terminal: ResizeTarget {
        var events: [String] = []
        var awaitsEcho = false
        func applySettled(_ size: CellSize) { events.append("settled \(size.cols)x\(size.rows)") }
        func applyLive(_ size: CellSize) { events.append("live \(size.cols)x\(size.rows)") }
    }

    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
    }

    @Test func aDragSendsLiveStepsThenTheLastGridSettledOnce() {
        var dragging = true
        let coordinator = ResizeCoordinator(holds: { _ in false }, resizesLive: { _ in dragging })
        let terminal = Terminal()
        let window = window()
        for cols in [81, 82, 83] {
            coordinator.submit(terminal, size: CellSize(cols: cols, rows: 24), window: window)
            _ = coordinator.tick()
        }
        #expect(terminal.events == ["live 81x24", "live 82x24", "live 83x24"], "\(terminal.events)")
        dragging = false
        #expect(coordinator.tick() == false, "the frames run on after the drag ended")
        #expect(terminal.events.last == "settled 83x24", "the drag's end did not settle: \(terminal.events)")
        #expect(terminal.events.filter { $0.hasPrefix("settled") }.count == 1, "\(terminal.events)")
        #expect(coordinator.tick() == false)
        #expect(terminal.events.count == 4, "the end settled more than once: \(terminal.events)")
    }

    /// Without a live resize every grid goes settled, as before.
    @Test func gridsOutsideADragGoSettled() {
        let coordinator = ResizeCoordinator(holds: { _ in false }, resizesLive: { _ in false })
        let terminal = Terminal()
        coordinator.submit(terminal, size: CellSize(cols: 90, rows: 30), window: window())
        _ = coordinator.tick()
        #expect(terminal.events == ["settled 90x30"])
    }

    /// A grid still waiting at the drag's end (its last grid has not echoed) settles the live
    /// resize itself when it goes, once.
    @Test func aWaitingGridAtTheDragsEndSettlesOnce() {
        var dragging = true
        let coordinator = ResizeCoordinator(holds: { _ in false }, resizesLive: { _ in dragging })
        let terminal = Terminal()
        let window = window()
        coordinator.submit(terminal, size: CellSize(cols: 81, rows: 24), window: window)
        _ = coordinator.tick()
        terminal.awaitsEcho = true
        coordinator.submit(terminal, size: CellSize(cols: 85, rows: 24), window: window)
        dragging = false
        _ = coordinator.tick()
        terminal.awaitsEcho = false
        _ = coordinator.tick()
        #expect(terminal.events == ["live 81x24", "settled 85x24"], "\(terminal.events)")
    }
}
