import Foundation
import Testing

@testable import CmuxAgentChat

/// Fixture lines mirror the real `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
/// format (Codex CLI 0.139), with content anonymized.
@Suite("CodexTranscriptParser")
struct CodexTranscriptParserTests {
    private let parser = CodexTranscriptParser()

    private func line(
        type: String,
        payload: [String: Any],
        timestamp: String = "2026-06-11T21:38:05.381Z"
    ) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "timestamp": timestamp, "type": type, "payload": payload,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func messageLine(role: String, texts: [String]) -> String {
        let blockType = role == "assistant" ? "output_text" : "input_text"
        return line(
            type: "response_item",
            payload: [
                "type": "message", "role": role,
                "content": texts.map { ["type": blockType, "text": $0] },
            ]
        )
    }

    private func functionCallLine(
        name: String,
        arguments: String,
        callID: String = "call_1"
    ) -> String {
        line(
            type: "response_item",
            payload: [
                "type": "function_call", "name": name,
                "arguments": arguments, "call_id": callID,
            ]
        )
    }

    private func outputLine(callID: String = "call_1", output: String) -> String {
        line(
            type: "response_item",
            payload: ["type": "function_call_output", "call_id": callID, "output": output]
        )
    }

    // MARK: - Session and prose

    @Test("session_meta maps to a sessionStarted status with the cwd as detail")
    func sessionMeta() {
        let metaLine = line(
            type: "session_meta",
            payload: [
                "id": "019eb89e-aaaa", "timestamp": "2026-06-11T21:38:03.916Z",
                "cwd": "/repo", "originator": "codex-tui", "cli_version": "0.139.0",
            ]
        )
        let result = parser.parse(lines: [metaLine], startingSeq: 0)
        #expect(result.messages.count == 1)
        let message = result.messages[0]
        #expect(message.role == .system)
        #expect(message.kind == .status(
            ChatStatusTransition(event: .sessionStarted, detail: "/repo")
        ))
    }

    @Test("user and assistant messages map to prose; injected context blocks are dropped")
    func proseMapping() {
        let lines = [
            messageLine(role: "developer", texts: ["<permissions instructions>\nstuff"]),
            messageLine(role: "user", texts: [
                "# AGENTS.md instructions for /repo\n<INSTRUCTIONS>...",
                "<environment_context>\n  <cwd>/repo</cwd>\n</environment_context>",
            ]),
            messageLine(role: "user", texts: ["fix the parser"]),
            messageLine(role: "assistant", texts: ["On it."]),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 2)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[0].kind == .prose(ChatProse(text: "fix the parser")))
        #expect(result.messages[0].seq == 2)
        #expect(result.messages[1].role == .agent)
        #expect(result.messages[1].kind == .prose(ChatProse(text: "On it.")))
    }

    @Test("user clipboard image path maps to attachment before remaining prose")
    func userClipboardAttachmentAndProse() {
        let path = "/tmp/x/clipboard-2026-07-08-101112-89abcdef.webp"
        let result = parser.parse(
            lines: [messageLine(role: "user", texts: ["\(path) check this"])],
            startingSeq: 0
        )
        #expect(result.messages.count == 2)
        guard case .attachment(let attachment) = result.messages[0].kind else {
            Issue.record("expected attachment")
            return
        }
        #expect(attachment.hostPath == path)
        #expect(attachment.displayName == "clipboard-2026-07-08-101112-89abcdef.webp")
        #expect(result.messages[1].kind == .prose(ChatProse(text: "check this")))
    }

    @Test("reasoning summaries concatenate into a thought; empty summaries are skipped")
    func reasoning() {
        let lines = [
            line(type: "response_item", payload: [
                "type": "reasoning", "summary": [], "encrypted_content": "gAAAA",
            ]),
            line(type: "response_item", payload: [
                "type": "reasoning",
                "summary": [
                    ["type": "summary_text", "text": "Inspect the file"],
                    ["type": "summary_text", "text": "Then run tests"],
                ],
            ]),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 1)
        #expect(result.messages[0].kind == .thought(
            ChatThought(text: "Inspect the file\n\nThen run tests")
        ))
    }

    // MARK: - Shell calls

    @Test("exec_command extracts the cmd string from the arguments JSON string")
    func execCommand() {
        let call = functionCallLine(
            name: "exec_command",
            arguments: #"{"cmd":"rg -n \"foo\" .","workdir":"/repo","yield_time_ms":10000}"#
        )
        let result = parser.parse(lines: [call], startingSeq: 7)
        #expect(result.messages.count == 1)
        #expect(result.messages[0].id == "call_1")
        #expect(result.messages[0].seq == 7)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == #"rg -n "foo" ."#)
        #expect(capture.isRunning)
    }

    @Test("shell extracts the script from a bash -lc command array")
    func shellCommandArray() {
        let call = functionCallLine(
            name: "shell",
            arguments: #"{"command":["bash","-lc","echo hi"],"timeout_ms":5000}"#
        )
        let result = parser.parse(lines: [call], startingSeq: 0)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "echo hi")
    }

    @Test("function_call_output in the same call completes the terminal with exit code and wall time")
    func outputSameCall() {
        let lines = [
            functionCallLine(name: "exec_command", arguments: #"{"cmd":"swift build"}"#),
            outputLine(output: "Chunk ID: 8f9491\nWall time: 1.5000 seconds\nProcess exited with code 0\nOutput:\nBuild complete!"),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 1)
        #expect(result.updatedMessages.isEmpty)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.exitCode == 0)
        #expect(capture.durationSeconds == 1.5)
        #expect(!capture.isRunning)
        #expect(capture.output?.contains("Build complete!") == true)
    }

    @Test("function_call_output in a later parse call re-emits via updatedMessages")
    func outputAcrossCalls() {
        let first = parser.parse(
            lines: [functionCallLine(name: "exec_command", arguments: #"{"cmd":"make"}"#, callID: "call_z")],
            startingSeq: 3
        )
        #expect(first.state.pendingToolUses.count == 1)
        let second = parser.parse(
            lines: [outputLine(callID: "call_z", output: "Process exited with code 1\nOutput:\nerror")],
            startingSeq: 4,
            state: first.state
        )
        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        let updated = second.updatedMessages[0]
        #expect(updated.id == "call_z")
        #expect(updated.seq == 3)
        guard case .terminal(let capture) = updated.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.exitCode == 1)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    // MARK: - Other tools

    @Test("non-shell function calls map to toolUse and JSON-object outputs fill exit info")
    func genericFunctionCall() {
        let lines = [
            functionCallLine(
                name: "update_plan",
                arguments: #"{"plan":[{"step":"do it","status":"pending"}]}"#,
                callID: "call_p"
            ),
            outputLine(
                callID: "call_p",
                output: #"{"output":"plan rejected","metadata":{"exit_code":2,"duration_seconds":0.1}}"#
            ),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        guard case .toolUse(let tool) = result.messages[0].kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "update_plan")
        #expect(tool.output == "plan rejected")
        #expect(tool.status == .failed)
        #expect(tool.inputDetail?.contains("plan") == true)
    }

    @Test("non-shell function call extracts referenced paths")
    func genericFunctionCallReferencedPaths() {
        let call = functionCallLine(
            name: "view_image",
            arguments: #"{"path":"/repo/screenshot.png","detail":"high"}"#
        )
        let result = parser.parse(lines: [call], startingSeq: 0)
        guard case .toolUse(let tool) = result.messages[0].kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.referencedPaths == ["/repo/screenshot.png"])
    }

    @Test("custom_tool_call apply_patch maps to toolUse with the first patched file in the summary")
    func applyPatch() {
        let patch = "*** Begin Patch\n*** Update File: /repo/Sources/App.swift\n@@\n-old\n+new\n*** End Patch"
        let lines = [
            line(type: "response_item", payload: [
                "type": "custom_tool_call", "status": "completed",
                "call_id": "call_ap", "name": "apply_patch", "input": patch,
            ]),
            line(type: "response_item", payload: [
                "type": "custom_tool_call_output", "call_id": "call_ap",
                "output": "Exit code: 0\nWall time: 0 seconds\nOutput:\nSuccess.",
            ]),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        guard case .toolUse(let tool) = result.messages[0].kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "apply_patch")
        #expect(tool.summary == "apply_patch /repo/Sources/App.swift")
        #expect(tool.referencedPaths == ["/repo/Sources/App.swift"])
        #expect(tool.status == .succeeded)
    }

    // MARK: - Robustness

    @Test("event_msg, turn_context, and malformed lines are skipped; seq tracks line offsets")
    func noiseAndSeq() {
        let lines = [
            line(type: "event_msg", payload: ["type": "task_started", "turn_id": "t-1"]),
            line(type: "turn_context", payload: ["turn_id": "t-1", "cwd": "/repo"]),
            line(type: "event_msg", payload: ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 5]]]),
            "garbage {",
            messageLine(role: "user", texts: ["hello"]),
        ]
        let result = parser.parse(lines: lines, startingSeq: 100)
        #expect(result.messages.count == 1)
        #expect(result.messages[0].seq == 104)
        #expect(result.messages[0].id == "line-104")
    }

    @Test("compacted lines map to a contextCompacted status")
    func compacted() {
        let result = parser.parse(
            lines: [line(type: "compacted", payload: ["message": "history replaced"])],
            startingSeq: 0
        )
        #expect(result.messages.count == 1)
        #expect(result.messages[0].kind == .status(
            ChatStatusTransition(event: .contextCompacted)
        ))
    }

    @Test("oversized tool output is truncated to the body budget")
    func truncation() {
        let huge = "Process exited with code 0\nOutput:\n" + String(repeating: "y", count: 40_000)
        let lines = [
            functionCallLine(name: "exec_command", arguments: #"{"cmd":"cat big"}"#),
            outputLine(output: huge),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect((capture.output?.count ?? 0) <= 16_385)
        #expect(capture.output?.hasSuffix("…") == true)
    }
}
