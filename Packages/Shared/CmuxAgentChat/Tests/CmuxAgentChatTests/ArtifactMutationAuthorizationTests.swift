import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Artifact mutation authorization")
struct ArtifactMutationAuthorizationTests {
    @Test("Failed Claude Write and Edit calls remain read-only references")
    func failedClaudeMutationsAreReferences() throws {
        let lines = [
            claudeLine(type: "assistant", content: [
                [
                    "type": "tool_use", "id": "write", "name": "Write",
                    "input": ["file_path": "/repo/new.md", "content": "draft"],
                ],
                [
                    "type": "tool_use", "id": "edit", "name": "Edit",
                    "input": [
                        "file_path": "/repo/existing.md",
                        "old_string": "old",
                        "new_string": "new",
                    ],
                ],
            ]),
            claudeLine(type: "user", content: [[
                "type": "tool_result", "tool_use_id": "write",
                "content": "permission denied", "is_error": true,
            ]]),
            claudeLine(type: "user", content: [[
                "type": "tool_result", "tool_use_id": "edit",
                "content": "permission denied", "is_error": true,
            ]]),
        ]

        let result = ClaudeTranscriptParser().parse(lines: lines, startingSeq: 0)
        let artifacts = indexedArtifacts(result)

        #expect(Set(artifacts.map(\.path)) == ["/repo/new.md", "/repo/existing.md"])
        #expect(artifacts.allSatisfy { $0.provenance == .referenced })
    }

    @Test("Failed Codex apply_patch remains a read-only reference")
    func failedCodexPatchIsReference() throws {
        let call = codexLine(type: "response_item", payload: [
            "type": "function_call",
            "name": "apply_patch",
            "arguments": #"{"patch":"*** Begin Patch\n*** Update File: generated.md\n@@\n-old\n+new\n*** End Patch"}"#,
            "call_id": "patch",
        ])
        let output = codexLine(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": "patch",
            "output": "Exit code: 1\nOutput:\npermission denied",
        ])

        let result = CodexTranscriptParser().parse(lines: [call, output], startingSeq: 0)
        let artifact = try #require(indexedArtifacts(result).first)

        #expect(artifact.path == "/repo/generated.md")
        #expect(artifact.provenance == .referenced)
    }

    @Test("Failed sidechain mutations do not grant created provenance")
    func failedSidechainMutationIsReference() throws {
        let invocation = claudeLine(type: "assistant", content: [[
            "type": "tool_use", "id": "side-write", "name": "Write",
            "input": ["file_path": "/tmp/side.md", "content": "draft"],
        ]], isSidechain: true)
        let failure = claudeLine(type: "user", content: [[
            "type": "tool_result", "tool_use_id": "side-write",
            "content": "permission denied", "is_error": true,
        ]], isSidechain: true)

        let result = ClaudeTranscriptParser().parse(lines: [invocation, failure], startingSeq: 0)
        let artifact = try #require(indexedArtifacts(result).first)

        #expect(artifact.path.hasSuffix("/tmp/side.md"))
        #expect(artifact.provenance == .referenced)
    }

    @Test("Successful sidechain authorization survives incremental parse calls")
    func successfulSidechainMutationAcrossParseCalls() throws {
        let invocation = claudeLine(type: "assistant", content: [[
            "type": "tool_use", "id": "side-write", "name": "Write",
            "input": ["file_path": "/tmp/side.md", "content": "draft"],
        ]], isSidechain: true)
        let parser = ClaudeTranscriptParser()
        let first = parser.parse(lines: [invocation], startingSeq: 0)
        let success = claudeLine(type: "user", content: [[
            "type": "tool_result", "tool_use_id": "side-write",
            "content": "saved", "is_error": false,
        ]], isSidechain: true)

        let second = parser.parse(lines: [success], startingSeq: 1, state: first.state)
        let artifact = try #require(indexedArtifacts(second).first)

        #expect(artifact.path.hasSuffix("/tmp/side.md"))
        #expect(artifact.provenance == .created)
        #expect(artifact.lastReferencedSeq == 1)
    }

    private func indexedArtifacts(
        _ result: ChatTranscriptParseResult
    ) -> [ChatArtifactIndexedReference] {
        ChatArtifactIndexedReference.derive(
            from: result.messages,
            supplementalReferences: result.artifactReferences,
            workingDirectory: "/repo"
        )
    }

    private func claudeLine(
        type: String,
        content: [[String: Any]],
        isSidechain: Bool = false
    ) -> String {
        json([
            "type": type,
            "isSidechain": isSidechain,
            "uuid": UUID().uuidString,
            "timestamp": "2026-07-21T12:00:00.000Z",
            "message": ["role": type == "assistant" ? "assistant" : "user", "content": content],
        ])
    }

    private func codexLine(type: String, payload: [String: Any]) -> String {
        json([
            "timestamp": "2026-07-21T12:00:00.000Z",
            "type": type,
            "payload": payload,
        ])
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
