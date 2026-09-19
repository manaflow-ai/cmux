import Foundation
import Testing

@testable import CmuxIrxTransport

@Suite struct IrxJournalTests {
    @Test func terminalTraceEventsAreRateLimitedBeforeRetention() {
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "terminal-trace")

        for index in 0...120 {
            journal.record(
                "terminal-trace",
                "phase-\(index)",
                ["trace_id": "0000000000000001"]
            )
        }

        #expect(journal.tail(200).count == 120)
        #expect(journal.counterSnapshot()["terminal_trace_dropped"] == 1)
    }
}
