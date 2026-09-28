import Foundation
import Testing
@testable import CmuxAgentChat

@Suite("Claude queued prompt ledger")
struct ClaudeQueuedPromptLedgerTests {
    private func line(_ operation: String, _ content: String? = nil, reason: String? = nil) -> Data {
        var object: [String: Any] = [
            "type": "queue-operation",
            "operation": operation,
            "timestamp": "2026-09-28T04:38:56.735Z",
            "sessionId": "session",
        ]
        if let content { object["content"] = content }
        if let reason { object["reason"] = reason }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// Applies `line` and reports whether the queue changed.
    private func apply(_ ledger: inout ClaudeQueuedPromptLedger, line: Data) -> Bool {
        ledger.apply(line: line)
    }

    @Test func enqueuedPromptsStayPendingUntilSentAbsorbedOrPopped() {
        var ledger = ClaudeQueuedPromptLedger()
        #expect(apply(&ledger, line: line("enqueue", "first")))
        #expect(apply(&ledger, line: line("enqueue", "second")))
        #expect(ledger.pending == ["first", "second"])

        #expect(apply(&ledger, line: line("remove", "second", reason: "absorbed_mid_turn")))
        #expect(ledger.pending == ["first"])

        #expect(apply(&ledger, line: line("dequeue")))
        #expect(ledger.count == 0)

        ledger.apply(line: line("enqueue", "third"))
        ledger.apply(line: line("enqueue", "fourth"))
        #expect(apply(&ledger, line: line("popAll", "third\nfourth")))
        #expect(ledger.count == 0)
    }

    @Test func otherTranscriptLinesAndStrayOperationsAreIgnored() {
        var ledger = ClaudeQueuedPromptLedger()
        let user = Data(#"{"type":"user","message":{"role":"user","content":"queue-operation"}}"#.utf8)
        #expect(!apply(&ledger, line: user))
        #expect(!apply(&ledger, line: Data("not json \"queue-operation\"".utf8)))
        // A resolution whose enqueue fell before the tail window.
        #expect(!apply(&ledger, line: line("dequeue")))
        #expect(!apply(&ledger, line: line("remove", "gone", reason: "delivered_to_agent")))
        #expect(ledger.count == 0)
    }

    @Test func queueTrackingIsBounded() {
        var ledger = ClaudeQueuedPromptLedger()
        for index in 0..<(ClaudeQueuedPromptLedger.maximumTrackedPrompts + 5) {
            ledger.apply(line: line("enqueue", "prompt \(index)"))
        }
        #expect(ledger.count == ClaudeQueuedPromptLedger.maximumTrackedPrompts)
    }
}

