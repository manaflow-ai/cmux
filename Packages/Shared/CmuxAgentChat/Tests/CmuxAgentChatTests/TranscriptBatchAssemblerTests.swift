import Foundation
import Testing

@testable import CmuxAgentChat

@Suite struct TranscriptBatchAssemblerTests {
    private static func toolUse(seq: Int) -> ChatMessage {
        ChatMessage(
            id: "m\(seq)",
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 1_781_000_000 + Double(seq)),
            kind: .toolUse(ChatToolUse(toolName: "Read", summary: "s\(seq)", status: .running))
        )
    }

    @Test("unresolved pending tool uses are bounded to the newest maxPendingToolUses")
    func pendingToolUsesBounded() {
        var assembler = TranscriptBatchAssembler(
            state: ChatTranscriptParseState(),
            budget: TranscriptTextBudget()
        )
        // Register more tool invocations than the cap, none ever resolved.
        let total = TranscriptBatchAssembler.maxPendingToolUses + 50
        for i in 0..<total {
            assembler.append(Self.toolUse(seq: i), pendingKey: "call-\(i)")
        }
        let state = assembler.result(lastTimestamp: nil).state
        // The carried state is capped, keeping the newest (highest-seq) calls
        // and evicting the oldest, instead of growing without bound.
        #expect(state.pendingToolUses.count == TranscriptBatchAssembler.maxPendingToolUses)
        #expect(state.pendingToolUses["call-\(total - 1)"] != nil)
        #expect(state.pendingToolUses["call-0"] == nil)
    }

    @Test("pending tool uses under the cap are all retained")
    func pendingUnderCapRetained() {
        var assembler = TranscriptBatchAssembler(
            state: ChatTranscriptParseState(),
            budget: TranscriptTextBudget()
        )
        for i in 0..<10 {
            assembler.append(Self.toolUse(seq: i), pendingKey: "call-\(i)")
        }
        let state = assembler.result(lastTimestamp: nil).state
        #expect(state.pendingToolUses.count == 10)
    }
}
