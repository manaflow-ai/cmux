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

    @Test("Claude failure text without an error flag remains read-only")
    func unflaggedClaudeFailureTextIsReference() throws {
        let invocation = claudeLine(type: "assistant", content: [[
            "type": "tool_use", "id": "unflagged-write", "name": "Write",
            "input": ["file_path": "/tmp/unflagged.md", "content": "draft"],
        ]])
        let failure = claudeLine(type: "user", content: [[
            "type": "tool_result", "tool_use_id": "unflagged-write",
            "content": "Error: permission denied",
        ]])

        let result = ClaudeTranscriptParser().parse(
            lines: [invocation, failure],
            startingSeq: 0
        )
        let artifact = try #require(indexedArtifacts(result).first)

        #expect(artifact.path.hasSuffix("/tmp/unflagged.md"))
        #expect(artifact.provenance == .referenced)
        #expect(artifact.captureAuthorization == nil)
    }

    @Test("Claude output without an error flag does not authorize a mutation")
    func unflaggedClaudeSuccessTextIsReference() throws {
        let invocation = claudeLine(type: "assistant", content: [[
            "type": "tool_use", "id": "unflagged-success", "name": "Write",
            "input": ["file_path": "/tmp/unflagged-success.md", "content": "draft"],
        ]])
        let result = claudeLine(type: "user", content: [[
            "type": "tool_result", "tool_use_id": "unflagged-success",
            "content": "saved",
        ]])

        let parsed = ClaudeTranscriptParser().parse(
            lines: [invocation, result],
            startingSeq: 0
        )
        let artifact = try #require(indexedArtifacts(parsed).first)

        #expect(artifact.path.hasSuffix("/tmp/unflagged-success.md"))
        #expect(artifact.provenance == .referenced)
        #expect(artifact.captureAuthorization == nil)
    }

    @Test("Claude textual exit code without an explicit success flag remains read-only")
    func unflaggedClaudeExitCodeIsReference() throws {
        let invocation = claudeLine(type: "assistant", content: [[
            "type": "tool_use", "id": "unflagged-exit", "name": "Write",
            "input": ["file_path": "/tmp/unflagged-exit.md", "content": "draft"],
        ]])
        let result = claudeLine(type: "user", content: [[
            "type": "tool_result", "tool_use_id": "unflagged-exit",
            "content": "Exit code: 0\nOutput: saved",
        ]])

        let parsed = ClaudeTranscriptParser().parse(
            lines: [invocation, result],
            startingSeq: 0
        )
        let artifact = try #require(indexedArtifacts(parsed).first)

        #expect(artifact.path.hasSuffix("/tmp/unflagged-exit.md"))
        #expect(artifact.provenance == .referenced)
        #expect(artifact.captureAuthorization == nil)
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

    @Test("Codex custom-tool textual exit headers do not authorize mutations")
    func codexCustomToolTextualExitHeaderIsReference() throws {
        let patch = "*** Begin Patch\n*** Add File: /tmp/textual-exit.md\n+draft\n*** End Patch"
        let call = codexLine(type: "response_item", payload: [
            "type": "custom_tool_call",
            "name": "apply_patch",
            "input": patch,
            "call_id": "custom-textual-exit",
        ])
        let output = codexLine(type: "response_item", payload: [
            "type": "custom_tool_call_output",
            "call_id": "custom-textual-exit",
            "output": "Exit code: 0\nOutput: success",
        ])

        let result = CodexTranscriptParser().parse(lines: [call, output], startingSeq: 0)
        let artifact = try #require(indexedArtifacts(result).first)

        #expect(artifact.provenance == .referenced)
        #expect(artifact.captureAuthorization == nil)
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

    @Test(
        "Successful shell append redirections remain references",
        arguments: [">>", "&>>"]
    )
    func successfulShellAppendRedirectionFailsClosed(_ redirect: String) throws {
        let call = codexLine(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "arguments": json([
                "cmd": "true \(redirect) /Users/me/private.json",
            ]),
            "call_id": "append",
        ])
        let output = codexLine(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": "append",
            "output": "Process exited with code 0\nOutput:\n",
        ])

        let result = CodexTranscriptParser().parse(lines: [call, output], startingSeq: 0)
        let artifact = try #require(
            indexedArtifacts(result).first { $0.path == "/Users/me/private.json" }
        )

        #expect(artifact.provenance == .referenced)
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

    @Test("Backtick command substitutions remain references")
    func backtickCommandSubstitutionFailsClosed() throws {
        let call = codexLine(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "arguments": json([
                "cmd": "echo `false > /Users/me/private.md`",
            ]),
            "call_id": "backtick",
        ])
        let output = codexLine(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": "backtick",
            "output": "Process exited with code 0\nOutput:\n",
        ])

        let result = CodexTranscriptParser().parse(lines: [call, output], startingSeq: 0)
        let artifact = try #require(
            indexedArtifacts(result).first { $0.path == "/Users/me/private.md" }
        )

        #expect(artifact.provenance == .referenced)
    }

    @Test("Shell comparison operators do not authorize artifact mutations")
    func shellConditionalComparisonFailsClosed() throws {
        let call = codexLine(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "arguments": #"{"cmd":"[[ z > /Users/me/private.md ]]"}"#,
            "call_id": "comparison",
        ])
        let output = codexLine(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": "comparison",
            "output": "Process exited with code 0\nOutput:\n",
        ])

        let result = CodexTranscriptParser().parse(lines: [call, output], startingSeq: 0)
        let artifact = try #require(
            indexedArtifacts(result).first { $0.path == "/Users/me/private.md" }
        )

        #expect(artifact.provenance == .referenced)
    }

    @Test("Shell read-write redirection does not authorize artifact creation")
    func shellReadWriteRedirectionFailsClosed() throws {
        let call = codexLine(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "arguments": #"{"cmd":"cat <> /Users/me/private.json"}"#,
            "call_id": "read-write",
        ])
        let output = codexLine(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": "read-write",
            "output": "Process exited with code 0\nOutput:\nprivate contents",
        ])

        let result = CodexTranscriptParser().parse(lines: [call, output], startingSeq: 0)
        let artifact = try #require(
            indexedArtifacts(result).first { $0.path == "/Users/me/private.json" }
        )

        #expect(artifact.provenance == .referenced)
    }

    @Test("Shell comments do not authorize artifact mutations")
    func shellCommentRedirectionFailsClosed() throws {
        let call = codexLine(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "arguments": #"{"cmd":"true # > /Users/me/private.json"}"#,
            "call_id": "comment",
        ])
        let output = codexLine(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": "comment",
            "output": "Process exited with code 0\nOutput:\n",
        ])

        let result = CodexTranscriptParser().parse(lines: [call, output], startingSeq: 0)
        let artifact = try #require(
            indexedArtifacts(result).first { $0.path == "/Users/me/private.json" }
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

    @Test("Successful sidechain Bash redirection is created across parse calls")
    func successfulSidechainBashAcrossParseCalls() throws {
        let invocation = claudeLine(type: "assistant", content: [[
            "type": "tool_use", "id": "side-bash", "name": "Bash",
            "input": ["command": "python render.py > /tmp/side-report.html"],
        ]], isSidechain: true)
        let parser = ClaudeTranscriptParser()
        let first = parser.parse(lines: [invocation], startingSeq: 0)
        let success = claudeLine(type: "user", content: [[
            "type": "tool_result", "tool_use_id": "side-bash",
            "content": "rendered", "is_error": false,
        ]], isSidechain: true)

        let second = parser.parse(lines: [success], startingSeq: 1, state: first.state)
        let artifact = try #require(indexedArtifacts(second).first)

        #expect(artifact.path.hasSuffix("/tmp/side-report.html"))
        #expect(artifact.provenance == .created)
        #expect(artifact.captureAuthorization == .created(sequence: 1))
    }

    @Test("Failed sidechain Bash redirection remains referenced")
    func failedSidechainBashRemainsReferenced() throws {
        let invocation = claudeLine(type: "assistant", content: [[
            "type": "tool_use", "id": "side-bash", "name": "Bash",
            "input": ["command": "python render.py > /tmp/side-report.html"],
        ]], isSidechain: true)
        let failure = claudeLine(type: "user", content: [[
            "type": "tool_result", "tool_use_id": "side-bash",
            "content": "permission denied", "is_error": true,
        ]], isSidechain: true)

        let result = ClaudeTranscriptParser().parse(
            lines: [invocation, failure],
            startingSeq: 0
        )
        let artifact = try #require(indexedArtifacts(result).first)

        #expect(artifact.path.hasSuffix("/tmp/side-report.html"))
        #expect(artifact.provenance == .referenced)
        #expect(artifact.captureAuthorization == nil)
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
