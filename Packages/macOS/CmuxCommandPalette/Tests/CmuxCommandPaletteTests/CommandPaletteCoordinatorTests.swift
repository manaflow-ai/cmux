import Testing
@testable import CmuxCommandPalette

@MainActor
@Suite struct CommandPaletteCoordinatorTests {
    private func row(_ id: String) -> CommandPaletteRenderResultRow {
        CommandPaletteRenderResultRow(id: id, title: id, matchedIndices: [], trailingLabel: nil)
    }

    /// Drains the coordinator's coalescing task, which yields once before
    /// applying, until `commandList` reaches `expected` or attempts run out.
    private func drain(
        _ coordinator: CommandPaletteCoordinator,
        until expected: CommandPaletteCommandListRenderState
    ) async {
        for _ in 0..<50 {
            if coordinator.commandList == expected { return }
            await Task.yield()
        }
    }

    @Test func startsEmpty() {
        let coordinator = CommandPaletteCoordinator()
        #expect(coordinator.commandList == .empty)
    }

    @Test func appliesScheduledUpdate() async {
        let coordinator = CommandPaletteCoordinator()
        let state = CommandPaletteCommandListRenderState(
            resultsVersion: 1,
            rows: [row("a")],
            selectedIndex: 0
        )
        coordinator.scheduleCommandListUpdate(state)
        await drain(coordinator, until: state)
        #expect(coordinator.commandList == state)
    }

    @Test func coalescesToNewestWithinTurn() async {
        let coordinator = CommandPaletteCoordinator()
        let first = CommandPaletteCommandListRenderState(resultsVersion: 1, rows: [row("a")])
        let second = CommandPaletteCommandListRenderState(resultsVersion: 2, rows: [row("b")])
        coordinator.scheduleCommandListUpdate(first)
        coordinator.scheduleCommandListUpdate(second)
        await drain(coordinator, until: second)
        #expect(coordinator.commandList == second)
    }

    @Test func dropsStaleResultsVersion() async {
        let coordinator = CommandPaletteCoordinator()
        let newer = CommandPaletteCommandListRenderState(resultsVersion: 5, rows: [row("new")])
        coordinator.scheduleCommandListUpdate(newer)
        await drain(coordinator, until: newer)
        let stale = CommandPaletteCommandListRenderState(resultsVersion: 2, rows: [row("stale")])
        coordinator.scheduleCommandListUpdate(stale)
        await Task.yield()
        await Task.yield()
        #expect(coordinator.commandList == newer)
    }
}
