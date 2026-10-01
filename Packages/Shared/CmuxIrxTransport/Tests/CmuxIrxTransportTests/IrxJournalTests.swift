import Foundation
import Testing

@testable import CmuxIrxTransport

@Suite struct IrxJournalTests {
    @Test func endpointIDsAreRedactedBeforeRetentionAndRendering() throws {
        let endpoint = V2IdentityKey().endpointID
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("irx-private-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "privacy", journalFileURL: file)
        journal.record("endpoint", "bound", ["endpoint_id": endpoint, "error": "peer \(endpoint) closed", "generation": "3"])
        let event = try #require(journal.tail().first)
        #expect(!event.attributes.values.contains { $0.contains(endpoint) })
        #expect(!IrxJournal.render(event).contains(endpoint))
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains(endpoint))
        #expect(event.attributes["generation"] == "3")
        let external = IrxJournalEvent(wallTime: Date(), monotonicMs: 0, component: "endpoint", event: "bound",
            attributes: ["endpoint_id": endpoint.uppercased()])
        #expect(!IrxJournal.render(external).contains(endpoint.uppercased()))
    }

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
