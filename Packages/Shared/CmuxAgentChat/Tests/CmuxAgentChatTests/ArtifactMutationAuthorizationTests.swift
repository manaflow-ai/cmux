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

    @Test("Codex custom-tool failure text without an exit status remains read-only")
    func codexCustomToolFailureWithoutExitStatusIsReference() throws {
        let patch = "*** Begin Patch\n*** Add File: /tmp/generated.md\n+draft\n*** End Patch"
        let call = codexLine(type: "response_item", payload: [
            "type": "custom_tool_call",
            "name": "apply_patch",
            "input": patch,
            "call_id": "custom-patch",
        ])
        let output = codexLine(type: "response_item", payload: [
            "type": "custom_tool_call_output",
            "call_id": "custom-patch",
            "output": "Script failed\napply_patch verification failed: context did not match",
        ])

        let result = CodexTranscriptParser().parse(lines: [call, output], startingSeq: 0)
        let artifact = try #require(indexedArtifacts(result).first)

        #expect(artifact.path.hasSuffix("/tmp/generated.md"))
        #expect(artifact.provenance == .referenced)
        guard case .toolUse(let toolUse) = try #require(result.messages.first).kind else {
            Issue.record("Expected a completed tool use")
            return
        }
        #expect(toolUse.status == .failed)
    }

    @Test("Unknown Codex custom-tool output does not authorize a mutation")
    func unknownCodexCustomToolOutputIsReference() throws {
        let patch = "*** Begin Patch\n*** Add File: /tmp/generated.md\n+draft\n*** End Patch"
        let call = codexLine(type: "response_item", payload: [
            "type": "custom_tool_call",
            "name": "apply_patch",
            "input": patch,
            "call_id": "custom-patch",
        ])
        let output = codexLine(type: "response_item", payload: [
            "type": "custom_tool_call_output",
            "call_id": "custom-patch",
            "output": "permission denied",
        ])

        let result = CodexTranscriptParser().parse(lines: [call, output], startingSeq: 0)
        let artifact = try #require(indexedArtifacts(result).first)

        #expect(artifact.path.hasSuffix("/tmp/generated.md"))
        #expect(artifact.provenance == .referenced)
    }

    @Test("Successful shell redirections are created but shell inputs remain references")
    func successfulShellRedirectionClassifiesOnlyOutputTargetAsCreated() throws {
        let renderCall = codexLine(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "arguments": #"{"cmd":"python3 render.py > /tmp/rendered.html"}"#,
            "call_id": "render",
        ])
        let renderOutput = codexLine(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": "render",
            "output": "Process exited with code 0\nOutput:\nrender complete",
        ])
        let readCall = codexLine(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "arguments": #"{"cmd":"cat /tmp/existing.md"}"#,
            "call_id": "read",
        ])
        let readOutput = codexLine(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": "read",
            "output": "Process exited with code 0\nOutput:\nexisting contents",
        ])

        let result = CodexTranscriptParser().parse(
            lines: [renderCall, renderOutput, readCall, readOutput],
            startingSeq: 0
        )
        let artifacts = indexedArtifacts(result)

        #expect(artifacts.first { $0.path.hasSuffix("/tmp/rendered.html") }?.provenance == .created)
        #expect(artifacts.first { $0.path.hasSuffix("/tmp/existing.md") }?.provenance == .referenced)
    }

    @Test("Unexecuted compound-shell redirections remain references")
    func compoundShellRedirectionFailsClosed() throws {
        let call = codexLine(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "arguments": #"{"cmd":"if false; then echo x > /tmp/report.md; fi"}"#,
            "call_id": "conditional",
        ])
        let output = codexLine(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": "conditional",
            "output": "Process exited with code 0\nOutput:\n",
        ])

        let result = CodexTranscriptParser().parse(lines: [call, output], startingSeq: 0)
        let artifact = try #require(
            indexedArtifacts(result).first { $0.path.hasSuffix("/tmp/report.md") }
        )

        #expect(artifact.provenance == .referenced)
    }

    @Test("Generic output flags do not authorize copying an external file")
    func genericOutputFlagFailsClosed() throws {
        let call = codexLine(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "arguments": #"{"cmd":"true --output /Users/me/private.json"}"#,
            "call_id": "true",
        ])
        let output = codexLine(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": "true",
            "output": "Process exited with code 0\nOutput:\n",
        ])

        let result = CodexTranscriptParser().parse(lines: [call, output], startingSeq: 0)
        let artifacts = indexedArtifacts(result)

        #expect(artifacts.first { $0.path == "/Users/me/private.json" }?.provenance == .referenced)
        #expect(artifacts.allSatisfy { $0.provenance == .referenced })
    }

    @Test("Option-bearing positional shell commands fail closed for mutation provenance")
    func positionalShellCommandFailsClosed() throws {
        let call = codexLine(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "arguments": #"{"cmd":"touch -r /Users/me/private.md /tmp/stamp.md"}"#,
            "call_id": "touch",
        ])
        let output = codexLine(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": "touch",
            "output": "Process exited with code 0\nOutput:\n",
        ])

        let result = CodexTranscriptParser().parse(lines: [call, output], startingSeq: 0)
        let artifacts = indexedArtifacts(result)

        #expect(artifacts.first { $0.path == "/Users/me/private.md" }?.provenance == .referenced)
        #expect(artifacts.allSatisfy { $0.provenance == .referenced })
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
