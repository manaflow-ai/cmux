import Foundation
import Testing

@testable import CmuxAgentChat

@Suite struct TranscriptBatchAssemblerTests {
    private static func toolUse(
        seq: Int,
        referencedPaths: [String]? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: "m\(seq)",
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: 1_781_000_000 + Double(seq)),
            kind: .toolUse(
                ChatToolUse(
                    toolName: "Read",
                    summary: "s\(seq)",
                    status: .running,
                    referencedPaths: referencedPaths
                )
            )
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

    @Test("pending tool-use paths are bounded by per-path and aggregate UTF-8 bytes")
    func pendingToolUsePathBytesBounded() {
        var assembler = TranscriptBatchAssembler(
            state: ChatTranscriptParseState(),
            budget: TranscriptTextBudget()
        )
        let oversized = "/tmp/" + String(repeating: "x", count: 5_000)
        for seq in 0..<300 {
            let paths = [oversized] + (0..<8).map { "/tmp/kept-\(seq)-\($0)-" + String(repeating: "y", count: 1_000) }
            assembler.append(
                Self.toolUse(seq: seq, referencedPaths: paths),
                pendingKey: "call-\(seq)"
            )
        }

        let pending = assembler.result(lastTimestamp: nil).state.pendingToolUses
        let pathValues = pending.values.flatMap { messages in
            messages.compactMap { message -> [String]? in
                guard case .toolUse(let toolUse) = message.kind else { return nil }
                return toolUse.referencedPaths
            }.flatMap { $0 }
        }
        let pathBytes = pathValues.reduce(0) { $0 + $1.utf8.count }

        #expect(pathBytes <= TranscriptBatchAssembler.maxPendingToolUsePathBytes)
        #expect(pathValues.allSatisfy {
            $0.utf8.count <= ChatToolReferencedPathExtractor.maximumPathBytes
        })
        #expect(!pathValues.contains(oversized))
        #expect(pending.count == TranscriptBatchAssembler.maxPendingToolUses)
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

    @Test("pending artifact mutation keys are bounded and included in the byte budget")
    func pendingArtifactMutationKeysBounded() {
        var assembler = TranscriptBatchAssembler(
            state: ChatTranscriptParseState(),
            budget: TranscriptTextBudget()
        )
        for key in 0..<400 {
            assembler.registerArtifactMutation(
                paths: ["/tmp/artifact.md"],
                pendingKey: String(repeating: "k", count: 1_000) + "-\(key)",
                seq: key
            )
        }

        let pending = assembler.result(lastTimestamp: nil).state.pendingArtifactMutations
        let carriedBytes = pending.reduce(0) { total, entry in
            total + entry.key.utf8.count
                + entry.value.reduce(0) { $0 + $1.path.utf8.count }
        }

        #expect(carriedBytes <= 256 * 1_024)
        #expect(pending.count < 400)
    }

    @Test("oversized persisted artifact mutation keys are discarded")
    func oversizedPersistedArtifactMutationKeyDiscarded() {
        let oversizedKey = String(repeating: "x", count: 10_000)
        let reference = ChatArtifactTranscriptReference(
            path: "/tmp/artifact.md",
            provenance: .referenced,
            seq: 1
        )
        var assembler = TranscriptBatchAssembler(
            state: ChatTranscriptParseState(
                pendingArtifactMutations: [oversizedKey: [reference]]
            ),
            budget: TranscriptTextBudget()
        )

        #expect(assembler.result(lastTimestamp: nil).state.pendingArtifactMutations.isEmpty)

        assembler.registerArtifactMutation(
            paths: [reference.path],
            pendingKey: oversizedKey,
            seq: 2
        )
        #expect(assembler.result(lastTimestamp: nil).state.pendingArtifactMutations.isEmpty)
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
