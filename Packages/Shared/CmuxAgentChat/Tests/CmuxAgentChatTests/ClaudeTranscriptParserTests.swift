import Foundation
import Testing

@testable import CmuxAgentChat

/// Fixture lines mirror the real `~/.claude/projects/<cwd>/<session>.jsonl`
/// format (Claude Code 2.1), with content anonymized.
@Suite("ClaudeTranscriptParser")
struct ClaudeTranscriptParserTests {
    let parser = ClaudeTranscriptParser()

    func userLine(
        uuid: String = "u-1",
        content: String,
        isMeta: Bool? = nil,
        timestamp: String? = "2026-06-12T05:07:51.103Z"
    ) -> String {
        var object: [String: Any] = [
            "parentUuid": NSNull(), "isSidechain": false, "type": "user",
            "message": ["role": "user", "content": content],
            "uuid": uuid, "cwd": "/tmp/x", "sessionId": "s-1", "version": "2.1.175",
        ]
        if let isMeta { object["isMeta"] = isMeta }
        if let timestamp { object["timestamp"] = timestamp }
        return Self.json(object)
    }

    func assistantLine(
        uuid: String = "a-1",
        blocks: [[String: Any]],
        timestamp: String = "2026-06-12T05:08:20.730Z"
    ) -> String {
        Self.json([
            "parentUuid": "u-1", "isSidechain": false, "type": "assistant",
            "message": [
                "model": "claude-fable-5", "id": "msg_01X", "type": "message",
                "role": "assistant", "content": blocks, "stop_reason": "tool_use",
            ],
            "uuid": uuid, "timestamp": timestamp, "sessionId": "s-1",
        ])
    }

    private func sidechainAssistantLine(blocks: [[String: Any]]) -> String {
        Self.json([
            "parentUuid": "u-1", "isSidechain": true, "type": "assistant",
            "message": ["role": "assistant", "content": blocks],
            "uuid": "side-1", "timestamp": "2026-06-12T05:08:20.730Z",
            "sessionId": "s-1",
        ])
    }

    private func toolResultLine(
        uuid: String = "r-1",
        toolUseID: String,
        content: Any,
        isError: Bool? = nil,
        timestamp: String = "2026-06-12T05:08:23.317Z"
    ) -> String {
        var block: [String: Any] = ["tool_use_id": toolUseID, "type": "tool_result", "content": content]
        if let isError { block["is_error"] = isError }
        return Self.json([
            "parentUuid": "a-1", "isSidechain": false, "type": "user",
            "message": ["role": "user", "content": [block]],
            "uuid": uuid, "timestamp": timestamp, "sessionId": "s-1",
        ])
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Prose, thoughts, noise

    // MARK: - Tools

    @Test("Bash tool_use maps to a running terminal capture")
    func bashToolUse() {
        let line = assistantLine(blocks: [
            ["type": "tool_use", "id": "toolu_b", "name": "Bash",
             "input": ["command": "swift test", "description": "Run tests"]],
        ])
        let result = parser.parse(lines: [line], startingSeq: 0)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "swift test")
        #expect(capture.isRunning)
        #expect(capture.output == nil)
    }

    @Test("tool_result in the same parse call completes the terminal in place")
    func bashResultSameCall() {
        let lines = [
            assistantLine(blocks: [
                ["type": "tool_use", "id": "toolu_b", "name": "Bash", "input": ["command": "ls"]],
            ]),
            toolResultLine(toolUseID: "toolu_b", content: "file-a\nfile-b"),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 1)
        #expect(result.updatedMessages.isEmpty)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.output == "file-a\nfile-b")
        #expect(capture.exitCode == 0)
        #expect(!capture.isRunning)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("tool_result in a later parse call re-emits the message via updatedMessages")
    func bashResultAcrossCalls() {
        let first = parser.parse(
            lines: [assistantLine(uuid: "a-b", blocks: [
                ["type": "tool_use", "id": "toolu_x", "name": "Bash", "input": ["command": "make"]],
            ])],
            startingSeq: 10
        )
        #expect(first.state.pendingToolUses.count == 1)
        let second = parser.parse(
            lines: [toolResultLine(toolUseID: "toolu_x", content: "done")],
            startingSeq: 11,
            state: first.state
        )
        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        let updated = second.updatedMessages[0]
        #expect(updated.id == "a-b")
        #expect(updated.seq == 10)
        guard case .terminal(let capture) = updated.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.output == "done")
        #expect(!capture.isRunning)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("error results parse the exit code and fail the tool")
    func errorResult() {
        let lines = [
            assistantLine(blocks: [
                ["type": "tool_use", "id": "toolu_e", "name": "Bash", "input": ["command": "false"]],
                ["type": "tool_use", "id": "toolu_g", "name": "Grep",
                 "input": ["pattern": "needle", "path": "/tmp"]],
            ]),
            toolResultLine(uuid: "r-e", toolUseID: "toolu_e", content: "Exit code 2\nboom", isError: true),
            toolResultLine(uuid: "r-g", toolUseID: "toolu_g", content: "No matches", isError: true),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.exitCode == 2)
        guard case .toolUse(let grep) = result.messages[1].kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(grep.status == .failed)
        #expect(grep.output == "No matches")
    }

    @Test("Edit tool maps to a fileEdit with line counts and a -/+ diff")
    func editTool() {
        let line = assistantLine(blocks: [
            ["type": "tool_use", "id": "toolu_ed", "name": "Edit",
             "input": ["file_path": "/repo/App.swift", "old_string": "let a = 1",
                       "new_string": "let a = 2\nlet b = 3", "replace_all": false]],
        ])
        let result = parser.parse(lines: [line], startingSeq: 0)
        guard case .fileEdit(let edit) = result.messages[0].kind else {
            Issue.record("expected fileEdit kind")
            return
        }
        #expect(edit.filePath == "/repo/App.swift")
        #expect(edit.operation == .edit)
        #expect(edit.additions == 2)
        #expect(edit.deletions == 1)
        #expect(edit.unifiedDiff == "-let a = 1\n+let a = 2\n+let b = 3")
    }

    @Test("Write tool maps to a write fileEdit counting content lines as additions")
    func writeTool() {
        let line = assistantLine(blocks: [
            ["type": "tool_use", "id": "toolu_w", "name": "Write",
             "input": ["file_path": "/repo/New.swift", "content": "one\ntwo\nthree"]],
        ])
        let result = parser.parse(lines: [line], startingSeq: 0)
        guard case .fileEdit(let edit) = result.messages[0].kind else {
            Issue.record("expected fileEdit kind")
            return
        }
        #expect(edit.operation == .write)
        #expect(edit.additions == 3)
        #expect(edit.deletions == 0)
    }

    @Test("MultiEdit and NotebookEdit map to file edits for Created provenance")
    func multiEditAndNotebookEditTools() {
        let line = assistantLine(blocks: [
            ["type": "tool_use", "id": "toolu_multi", "name": "MultiEdit",
             "input": ["file_path": "Sources/App.swift", "edits": [[
                "old_string": "old", "new_string": "new",
             ]]]],
            ["type": "tool_use", "id": "toolu_notebook", "name": "NotebookEdit",
             "input": ["notebook_path": "Notes/Research.ipynb", "old_string": "a",
                       "new_source": "b"]],
        ])
        let messages = parser.parse(lines: [line], startingSeq: 0).messages
        let edits = messages.compactMap { message -> ChatFileEdit? in
            guard case .fileEdit(let edit) = message.kind else { return nil }
            return edit
        }
        #expect(edits.map(\.filePath) == ["Sources/App.swift", "Notes/Research.ipynb"])
        let artifacts = ChatArtifactIndexedReference.derive(
            from: messages,
            workingDirectory: "/repo"
        )
        #expect(Set(artifacts.map(\.path)) == [
            "/repo/Sources/App.swift",
            "/repo/Notes/Research.ipynb",
        ])
        #expect(artifacts.allSatisfy { $0.provenance == .created })
    }

    @Test("unknown tools map to a generic toolUse with summary and input detail")
    func genericTool() {
        let line = assistantLine(blocks: [
            ["type": "tool_use", "id": "toolu_r", "name": "Read",
             "input": ["file_path": "/repo/main.swift"]],
        ])
        let result = parser.parse(lines: [line], startingSeq: 0)
        guard case .toolUse(let tool) = result.messages[0].kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "Read")
        #expect(tool.summary == "Read /repo/main.swift")
        #expect(tool.inputDetail?.contains("file_path") == true)
        #expect(tool.status == .running)
        #expect(tool.referencedPaths == ["/repo/main.swift"])
    }

    @Test("ChatToolUse wire coding preserves optional referenced paths and decodes legacy payloads")
    func toolReferencedPathsWireCoding() throws {
        let coding = ChatWireCoding()
        let tool = ChatToolUse(
            toolName: "Read",
            summary: "Read /repo/main.swift",
            referencedPaths: ["/repo/main.swift"]
        )
        let decoded = try coding.decode(ChatToolUse.self, from: try coding.encode(tool))
        #expect(decoded.referencedPaths == ["/repo/main.swift"])

        let legacy = Data(#"{"tool_name":"Read","summary":"Read /repo/main.swift","status":"running"}"#.utf8)
        let legacyDecoded = try coding.decode(ChatToolUse.self, from: legacy)
        #expect(legacyDecoded.referencedPaths == nil)
    }

    @Test("AskUserQuestion maps to a question and its result fills the selected answer")
    func askUserQuestion() {
        let lines = [
            assistantLine(blocks: [
                ["type": "tool_use", "id": "toolu_q", "name": "AskUserQuestion",
                 "input": ["questions": [[
                    "question": "Which path?", "header": "Path", "multiSelect": false,
                    "options": [
                        ["label": "Fast", "description": "Quick but rough"],
                        ["label": "Slow", "description": "Thorough"],
                    ],
                 ]]]],
            ]),
            toolResultLine(
                toolUseID: "toolu_q",
                content: "Your questions have been answered: \"Which path?\"=\"Slow\". You can now continue with these answers in mind."
            ),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 1)
        guard case .question(let question) = result.messages[0].kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(question.prompt == "Which path?")
        #expect(question.options.map(\.label) == ["Fast", "Slow"])
        #expect(question.options[0].detail == "Quick but rough")
        #expect(question.selectedOptionLabel == "Slow")
    }

    @Test("a multi-question AskUserQuestion resolves every card by its prompt")
    func multiQuestionAskUserQuestion() {
        let lines = [
            assistantLine(blocks: [
                ["type": "tool_use", "id": "toolu_multi", "name": "AskUserQuestion",
                 "input": ["questions": [
                    ["question": "Which path?", "header": "Path", "multiSelect": false,
                     "options": [["label": "Fast", "description": "rough"],
                                 ["label": "Slow", "description": "thorough"]]],
                    ["question": "Which env?", "header": "Env", "multiSelect": false,
                     "options": [["label": "Dev", "description": "local"],
                                 ["label": "Prod", "description": "live"]]],
                 ]]],
            ]),
            toolResultLine(
                toolUseID: "toolu_multi",
                content: "Your questions have been answered: \"Which path?\"=\"Slow\", \"Which env?\"=\"Dev\". Continue."
            ),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        let questions = result.messages.compactMap { msg -> ChatQuestion? in
            if case .question(let q) = msg.kind { return q }
            return nil
        }
        #expect(questions.count == 2)
        // Both cards must be resolved (not left actionable), each with its
        // own answer matched by prompt.
        #expect(questions.first(where: { $0.prompt == "Which path?" })?.selectedOptionLabel == "Slow")
        #expect(questions.first(where: { $0.prompt == "Which env?" })?.selectedOptionLabel == "Dev")
    }

    @Test("a sidechain line's timestamp does not leak into a later visible line")
    func sidechainTimestampDoesNotLeak() {
        let lines = [
            userLine(uuid: "u-real", content: "first", timestamp: "2026-06-12T10:00:00.000Z"),
            { var d: [String: Any] = [
                "parentUuid": NSNull(), "isSidechain": true, "type": "assistant",
                "message": ["role": "assistant", "content": [["type": "text", "text": "subagent work"]]],
                "uuid": "side-x", "sessionId": "s-1",
                "timestamp": "2026-06-12T23:59:59.000Z",
              ]; return Self.json(d) }(),
            // visible assistant line with NO timestamp: must inherit the
            // visible user line's 10:00, not the sidechain's 23:59.
            { var d: [String: Any] = [
                "parentUuid": NSNull(), "isSidechain": false, "type": "assistant",
                "message": ["role": "assistant", "content": [["type": "text", "text": "real reply"]]],
                "uuid": "a-real", "sessionId": "s-1",
              ]; return Self.json(d) }(),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        guard let reply = result.messages.first(where: {
            if case .prose(let p) = $0.kind { return p.text == "real reply" }
            return false
        }) else { Issue.record("missing real reply"); return }
        #expect(reply.timestamp == ISO8601DateFormatter().date(from: "2026-06-12T10:00:00Z"))
    }

    @Test("tool_result content arrays join their text blocks")
    func toolResultArrayContent() {
        let lines = [
            assistantLine(blocks: [
                ["type": "tool_use", "id": "toolu_a", "name": "Read", "input": ["file_path": "/x"]],
            ]),
            toolResultLine(
                toolUseID: "toolu_a",
                content: [
                    ["type": "text", "text": "first"],
                    ["type": "tool_reference", "tool_name": "TaskCreate"],
                    ["type": "text", "text": "second"],
                ]
            ),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        guard case .toolUse(let tool) = result.messages[0].kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.output == "first\nsecond")
        #expect(tool.status == .succeeded)
    }

    // MARK: - Robustness

    @Test("sidechain lines are skipped while still consuming their seq")
    func sidechainLines() {
        var sidechain: [String: Any] = [
            "parentUuid": NSNull(), "isSidechain": true, "type": "user",
            "message": ["role": "user", "content": "injected subagent prompt"],
            "uuid": "side-1", "sessionId": "s-1",
            "timestamp": "2026-06-12T05:07:51.103Z",
        ]
        let lines = [
            Self.json(sidechain),
            userLine(uuid: "u-real", content: "the human's prompt"),
        ]
        let result = parser.parse(lines: lines, startingSeq: 10)
        #expect(result.messages.count == 1)
        #expect(result.messages[0].seq == 11)
        guard case .prose(let prose) = result.messages[0].kind else {
            Issue.record("expected prose")
            return
        }
        #expect(prose.text == "the human's prompt")
    }

    @Test("sidechain mutation content with interior whitespace is not an artifact path")
    func sidechainMutationMultilineContentIsNotArtifact() {
        let line = sidechainAssistantLine(blocks: [
            ["type": "tool_use", "id": "toolu_js", "name": "Write", "input": [
                "file_path": "/tmp/app.js",
                "content": "// generated file\n/usr/local/bin/tool --flag",
            ]],
            ["type": "tool_use", "id": "toolu_c", "name": "Write", "input": [
                "file_path": "/tmp/app.c",
                "content": "/usr/include/stdio.h\nint main(void) { return 0; }",
            ]],
        ])
        let result = parser.parse(lines: [line], startingSeq: 7)

        #expect(result.messages.isEmpty)
        #expect(result.artifactReferences == [
            ChatArtifactTranscriptReference(path: "/tmp/app.js", provenance: .created, seq: 7),
            ChatArtifactTranscriptReference(path: "/tmp/app.c", provenance: .created, seq: 7),
        ])
    }

    @Test("only a sidechain mutation target is created")
    func sidechainMutationTargetProvenance() {
        let line = sidechainAssistantLine(blocks: [[
            "type": "tool_use", "id": "toolu_write", "name": "Write",
            "input": ["file_path": "/tmp/a", "content": "/tmp/b"],
        ]])
        let result = parser.parse(lines: [line], startingSeq: 9)

        #expect(result.messages.isEmpty)
        #expect(result.artifactReferences == [
            ChatArtifactTranscriptReference(path: "/tmp/a", provenance: .created, seq: 9),
            ChatArtifactTranscriptReference(path: "/tmp/b", provenance: .referenced, seq: 9),
        ])
    }

    @Test("malformed lines are skipped without affecting seq assignment")
    func malformedLines() {
        let lines = [
            "not json at all",
            "{\"type\": \"user\", truncated",
            "[1, 2, 3]",
            userLine(uuid: "u-ok", content: "still works"),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 1)
        #expect(result.messages[0].seq == 3)
    }

    @Test("oversized outputs are truncated to the body budget")
    func truncation() {
        let huge = String(repeating: "x", count: 40_000)
        let lines = [
            userLine(content: huge),
            assistantLine(blocks: [
                ["type": "tool_use", "id": "toolu_t", "name": "Bash", "input": ["command": "cat big"]],
            ]),
            toolResultLine(toolUseID: "toolu_t", content: huge),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        guard case .prose(let prose) = result.messages[0].kind else {
            Issue.record("expected prose kind")
            return
        }
        #expect(prose.text.count <= 16_385)
        #expect(prose.text.hasSuffix("…"))
        guard case .terminal(let capture) = result.messages[1].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect((capture.output?.count ?? 0) <= 16_385)
    }

    @Test("lines without a timestamp inherit the previous line's timestamp")
    func timestampFallback() {
        let lines = [
            userLine(uuid: "u-a", content: "first", timestamp: "2026-06-12T05:07:51.103Z"),
            userLine(uuid: "u-b", content: "second", timestamp: nil),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 2)
        #expect(result.messages[1].timestamp == result.messages[0].timestamp)
        let expected = try? Date(
            "2026-06-12T05:07:51.103Z",
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        )
        #expect(result.messages[0].timestamp == expected)
    }
}
