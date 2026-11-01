import AppKit
import CmuxNextBridge
import CmuxNextTestSupport
import struct CmuxNextDaemon.CellSize
import Testing

/// A pane's final grid goes to its PTY at the start of a split or a close (Lawrence 2026-10-23), in the
/// caller's turn; the one-in-flight echo rule still keeps only the newest. A window's full screen
/// transition holds its own terminals' grids, never another window's (PL-burst M6).
@MainActor
@Suite(.closesItsWindows) struct ResizeCoordinatorFinalGridTests {
    final class Terminal: ResizeTarget {
        var applied: [CellSize] = []
        var awaitsEcho = false
        func applySettled(_ size: CellSize) { applied.append(size) }
    }

    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
    }

    @Test func aFinalGridGoesInTheCallersTurn() {
        let coordinator = ResizeCoordinator(holds: { _ in false })
        let terminal = Terminal()
        let win = window()
        defer { win.closeAfterTest() }
        coordinator.submitFinal(terminal, size: CellSize(cols: 90, rows: 40), window: win)
        #expect(terminal.applied == [CellSize(cols: 90, rows: 40)], "applied \(terminal.applied) in the caller's turn")
        #expect(coordinator.tick() == false, "the frames run on after the final grid went")
        #expect(terminal.applied.count == 1, "the final grid went \(terminal.applied.count) times")
    }

    /// Five Cmd-D presses while the first grid has not echoed: the newest final grid goes once, the
    /// frame the echo comes.
    @Test func aBurstSendsOnlyTheNewestFinalGridOnceTheEchoComes() {
        let coordinator = ResizeCoordinator(holds: { _ in false })
        let terminal = Terminal()
        coordinator.submitFinal(terminal, size: CellSize(cols: 100, rows: 40))
        terminal.awaitsEcho = true
        for cols in [80, 66, 57, 50] {
            coordinator.submitFinal(terminal, size: CellSize(cols: cols, rows: 40))
            _ = coordinator.tick()
        }
        #expect(terminal.applied == [CellSize(cols: 100, rows: 40)], "sent \(terminal.applied) before the echo")
        terminal.awaitsEcho = false
        #expect(coordinator.tick() == false)
        #expect(terminal.applied == [CellSize(cols: 100, rows: 40), CellSize(cols: 50, rows: 40)], "sent \(terminal.applied)")
    }

    /// One window enters full screen: its terminal's grids (the final one too) wait until it ends; a
    /// terminal in another window resizes on time.
    @Test func aFullScreenTransitionHoldsOnlyItsOwnWindowsGrids() {
        let entering = window(), other = window()
        defer { entering.closeAfterTest(); other.closeAfterTest() }
        var transitioning: Set<ObjectIdentifier> = [ObjectIdentifier(entering)]
        let coordinator = ResizeCoordinator(holds: { $0.map { transitioning.contains(ObjectIdentifier($0)) } ?? false })
        let inside = Terminal(), outside = Terminal(), final = Terminal()
        coordinator.submit(inside, size: CellSize(cols: 200, rows: 50), window: entering)
        coordinator.submitFinal(final, size: CellSize(cols: 120, rows: 50), window: entering)
        coordinator.submit(outside, size: CellSize(cols: 70, rows: 30), window: other)
        #expect(coordinator.tick(), "the frames stop while a window holds grids")
        #expect(outside.applied == [CellSize(cols: 70, rows: 30)], "another window's transition held this grid")
        #expect(inside.applied.isEmpty && final.applied.isEmpty, "the transitioning window's grids went mid-animation")
        transitioning.removeAll()
        _ = coordinator.tick()
        #expect(inside.applied == [CellSize(cols: 200, rows: 50)])
        #expect(final.applied == [CellSize(cols: 120, rows: 50)])
    }
}
