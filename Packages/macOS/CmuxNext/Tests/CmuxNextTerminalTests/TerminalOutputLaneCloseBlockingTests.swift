#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
@testable import CmuxNextTerminal
import Foundation
import Testing

/// `TerminalOutputLane.close(then:)` runs on the main thread each time a terminal surface is freed (the view's
/// deinit): it never waits for the lane (the lane's last block posts `ghostty_surface_free`), so the blocking
/// detector records nothing and a Debug build started with `CMUX_BLOCKING_TRAP=1` does not stop
/// (plans/cmux-next/chrome-parity/p02-threads.md, task 035). The lane's parse is a no-op recorder, so no
/// Ghostty surface is made.
@Suite(.timeLimit(.minutes(1))) struct TerminalOutputLaneCloseBlockingTests {
    @MainActor @Test func closingALaneOnTheMainThreadRecordsNothing() async {
        let table = BlockingViolationTable(mode: .record)
        BlockingViolationTable.$scoped.withValue(table) {
            let lane = TerminalOutputLane(surface: TerminalOutputLaneHangScopeTests.surface, label: "test.terminal-close") { _, _ in }
            lane.processOutput(Data("chunk".utf8))
            lane.close {}
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty, "a terminal close recorded a main-thread wait")
    }

    #if DEBUG
    @Test func closingALaneOnTheMainThreadDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            await BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .trap)) {
                await MainActor.run {
                    let lane = TerminalOutputLane(surface: TerminalOutputLaneHangScopeTests.surface, label: "test.terminal-close") { _, _ in }
                    lane.processOutput(Data("chunk".utf8))
                    lane.close {}
                }
            }
        }
    }
    #endif
}
#endif
