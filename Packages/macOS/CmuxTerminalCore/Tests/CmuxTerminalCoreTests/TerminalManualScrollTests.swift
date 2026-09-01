import Testing
import CmuxTerminalCore

@Suite("manual terminal scrolling")
struct TerminalManualScrollTests {
    private func event(
        y: Double,
        precise: Bool = false,
        cellHeight: Double = 20,
        column: UInt16? = 4,
        row: UInt16? = 7,
        modifiers: UInt8 = 0
    ) -> TerminalManualScrollEvent {
        TerminalManualScrollEvent(
            deltaX: 0,
            deltaY: y,
            isPrecise: precise,
            cellHeightPixels: cellHeight,
            column: column,
            row: row,
            modifiers: modifiers
        )
    }

    @Test func nonPreciseTicksBecomeRowsAndPreservePosition() {
        var quantizer = TerminalManualScrollQuantizer()
        let command = quantizer.command(for: event(y: 2, modifiers: 0b0101))
        #expect(command == TerminalScrollCommand(
            direction: .up,
            lines: 2,
            source: .wheel,
            column: 4,
            row: 7,
            modifiers: 0b0101
        ))
    }

    @Test func preciseDeltasAccumulateUntilOneCell() {
        var quantizer = TerminalManualScrollQuantizer()
        #expect(quantizer.command(for: event(y: 8, precise: true)) == nil)
        #expect(quantizer.command(for: event(y: 12, precise: true)) == TerminalScrollCommand(
            direction: .up,
            lines: 1,
            source: .wheel,
            column: 4,
            row: 7
        ))
    }

    @Test func preciseRemainderCanBeCancelledByReverseGesture() {
        var quantizer = TerminalManualScrollQuantizer()
        #expect(quantizer.command(for: event(y: 12, precise: true)) == nil)
        #expect(quantizer.command(for: event(y: -12, precise: true)) == nil)
        #expect(quantizer.command(for: event(y: 20, precise: true)) == TerminalScrollCommand(
            direction: .up,
            lines: 1,
            source: .wheel,
            column: 4,
            row: 7
        ))
    }

    @Test func zeroAndInvalidDeltasDoNotCreateCommands() {
        var quantizer = TerminalManualScrollQuantizer()
        #expect(quantizer.command(for: event(y: 0)) == nil)
        #expect(quantizer.command(for: event(y: 1, precise: true, cellHeight: 0)) == nil)
    }
}
