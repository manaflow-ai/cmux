import CmuxNextBridge
import struct CmuxNextDaemon.CellSize
import Testing

/// A pane's final grid goes to its PTY at the start of a split or a close (Lawrence 2026-10-23), in the
/// caller's turn, whatever holds the grids; the one-in-flight echo rule still keeps only the newest.
@MainActor
@Suite struct ResizeCoordinatorFinalGridTests {
    final class Terminal: ResizeTarget {
        var applied: [CellSize] = []
        var awaitsEcho = false
        func applySettled(_ size: CellSize) { applied.append(size) }
    }

    final class Holder {}

    @Test func aFinalGridGoesInTheCallersTurnWhileALayoutHoldsTheGrids() {
        let coordinator = ResizeCoordinator(holds: { false })
        let terminal = Terminal(), holder = Holder()
        coordinator.setHeld(true, by: holder)
        coordinator.submitFinal(terminal, size: CellSize(cols: 90, rows: 40))
        #expect(terminal.applied == [CellSize(cols: 90, rows: 40)], "applied \(terminal.applied) in the caller's turn")
        for _ in 0..<5 { _ = coordinator.tick() }
        coordinator.setHeld(false, by: holder)
        for _ in 0..<5 { _ = coordinator.tick() }
        #expect(terminal.applied.count == 1, "the final grid went \(terminal.applied.count) times")
    }

    /// Five Cmd-D presses while the first grid has not echoed: the newest final grid goes once, the
    /// frame the echo comes, even while a layout holds the other grids.
    @Test func aBurstSendsOnlyTheNewestFinalGridOnceTheEchoComes() {
        let coordinator = ResizeCoordinator(holds: { false })
        let terminal = Terminal(), other = Terminal(), holder = Holder()
        coordinator.submitFinal(terminal, size: CellSize(cols: 100, rows: 40))
        terminal.awaitsEcho = true
        coordinator.setHeld(true, by: holder)
        coordinator.submit(other, size: CellSize(cols: 50, rows: 40))
        for cols in [80, 66, 57, 50] {
            coordinator.submitFinal(terminal, size: CellSize(cols: cols, rows: 40))
            _ = coordinator.tick()
        }
        #expect(terminal.applied == [CellSize(cols: 100, rows: 40)], "sent \(terminal.applied) before the echo")
        terminal.awaitsEcho = false
        #expect(coordinator.tick() == false, "the frames run on with nothing but held grids")
        #expect(terminal.applied == [CellSize(cols: 100, rows: 40), CellSize(cols: 50, rows: 40)], "sent \(terminal.applied)")
        #expect(other.applied.isEmpty, "a held grid went: \(other.applied)")
    }

    /// A full screen transition still holds every grid, the final one too, until it ends.
    @Test func aFullScreenTransitionHoldsAFinalGridUntilItEnds() {
        var transitioning = true
        let coordinator = ResizeCoordinator(holds: { transitioning })
        let terminal = Terminal()
        coordinator.submitFinal(terminal, size: CellSize(cols: 120, rows: 50))
        _ = coordinator.tick()
        #expect(terminal.applied.isEmpty)
        transitioning = false
        _ = coordinator.tick()
        #expect(terminal.applied == [CellSize(cols: 120, rows: 50)])
    }
}
