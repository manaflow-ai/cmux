import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct SnapshotPollerTests {
    private func makeGrid(_ char: String) -> CellGrid {
        let cell = Cell(t: char, wide: .narrow, fg: .default, bg: .default,
                        attrs: [], underlineKind: nil, underlineColor: nil,
                        hyperlink: nil, semantic: nil)
        let row = CellRow(wrap: false, wrapContinuation: false, cells: [cell])
        return CellGrid(cols: 1, rows: 1, altScreen: false, title: nil,
                        cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
                        semanticAvailable: false, rowsData: [row])
    }

    @Test func emitsOnFirstTick() async throws {
        let clock = ManualClock()
        let emitted = EmittedCounter()
        let poller = SnapshotPoller(
            interval: 0.1, clock: clock,
            read: { self.makeGrid("a") },
            emit: { _ in await emitted.bump() }
        )
        try await poller.tick()
        let count = await emitted.value
        #expect(count == 1)
    }

    @Test func suppressesEmitWhenDigestUnchanged() async throws {
        let clock = ManualClock()
        let emitted = EmittedCounter()
        let poller = SnapshotPoller(
            interval: 0.1, clock: clock,
            read: { self.makeGrid("a") },
            emit: { _ in await emitted.bump() }
        )
        try await poller.tick()
        try await poller.tick()
        try await poller.tick()
        let count = await emitted.value
        #expect(count == 1, "identical grids should produce one emit")
    }

    @Test func emitsAgainAfterGridChanges() async throws {
        let clock = ManualClock()
        let emitted = EmittedCounter()
        let state = GridState()
        await state.set("a")
        let poller = SnapshotPoller(
            interval: 0.1, clock: clock,
            read: { self.makeGrid(await state.value) },
            emit: { _ in await emitted.bump() }
        )
        try await poller.tick()
        try await poller.tick()
        await state.set("b")
        try await poller.tick()
        try await poller.tick()
        let count = await emitted.value
        #expect(count == 2)
    }
}

private actor EmittedCounter {
    var value: Int = 0
    func bump() { value += 1 }
}

private actor GridState {
    var value: String = ""
    func set(_ v: String) { value = v }
}
