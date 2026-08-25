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

    @Test("pending artifact mutation references are bounded by count")
    func pendingArtifactMutationReferenceCountBounded() {
        var assembler = TranscriptBatchAssembler(
            state: ChatTranscriptParseState(),
            budget: TranscriptTextBudget()
        )
        for key in 0..<2_000 {
            assembler.registerArtifactMutation(
                paths: ["/tmp/artifact-\(key).md"],
                pendingKey: "mutation-\(key)",
                seq: key
            )
        }

        let pending = assembler.result(lastTimestamp: nil).state.pendingArtifactMutations
        let referenceCount = pending.values.reduce(0) { $0 + $1.count }

        #expect(referenceCount <= 1_024)
        #expect(pending["mutation-1_999"] != nil)
        #expect(pending["mutation-0"] == nil)
    }

    @Test("pending artifact mutation references are bounded by UTF-8 bytes")
    func pendingArtifactMutationBytesBounded() {
        var assembler = TranscriptBatchAssembler(
            state: ChatTranscriptParseState(),
            budget: TranscriptTextBudget()
        )
        let pathPrefix = "/tmp/" + String(repeating: "x", count: 1_000)
        for key in 0..<400 {
            let paths = (0..<8).map { "\(pathPrefix)-\(key)-\($0).md" }
            assembler.registerArtifactMutation(
                paths: paths,
                pendingKey: "mutation-\(key)",
                seq: key
            )
        }

        let pending = assembler.result(lastTimestamp: nil).state.pendingArtifactMutations
        let byteCount = pending.values
            .flatMap { $0 }
            .reduce(0) { $0 + $1.path.utf8.count }

        #expect(byteCount <= 256 * 1_024)
    }

    @Test("supplemental artifact references are bounded during one parse")
    func artifactReferencesBoundedDuringParse() {
        var assembler = TranscriptBatchAssembler(
            state: ChatTranscriptParseState(),
            budget: TranscriptTextBudget()
        )
        assembler.appendArtifactReferences(
            paths: (0..<20_000).map { "/tmp/reference-\($0).md" },
            seq: 1
        )

        let references = assembler.result(lastTimestamp: nil).artifactReferences
        #expect(references.count <= 4_096)
        #expect(references.reduce(0) { $0 + $1.path.utf8.count } <= 512 * 1_024)
    }
}
