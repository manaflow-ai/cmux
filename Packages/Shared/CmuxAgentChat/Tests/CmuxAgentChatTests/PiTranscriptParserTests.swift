import Foundation
import Testing

@testable import CmuxAgentChat

/// Fixture lines mirror anonymized OMP 17.1.8 session format v3 JSONL.
@Suite("PiTranscriptParser")
struct PiTranscriptParserTests {
    private let parser = PiTranscriptParser()

    @Test("v3 session header maps to a session-started status")
    func sessionHeader() {
        let result = parser.parse(lines: [headerLine()], startingSeq: 7)

        #expect(result.messages.count == 1)
        let message = result.messages[0]
        #expect(message.seq == 7)
        #expect(message.role == .system)
        #expect(message.kind == .status(
            ChatStatusTransition(event: .sessionStarted, detail: "/work/anonymized-project")
        ))
    }

    @Test("wrapped user and assistant text plus thinking map to typed chat messages")
    func proseAndThinking() {
        let lines = [
            userLine(id: "u0000001", text: "Inspect the parser."),
            assistantLine(
                id: "a0000001",
                parentID: "u0000001",
                content: [
                    ["type": "thinking", "thinking": "I should inspect the format first."],
                    ["type": "text", "text": "I found the relevant entry."],
                ]
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 20)

        #expect(result.messages.count == 3)
        #expect(result.messages[0].id == "u0000001")
        #expect(result.messages[0].seq == 20)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[0].kind == .prose(ChatProse(text: "Inspect the parser.")))
        #expect(result.messages[1].seq == 21)
        #expect(result.messages[1].kind == .thought(
            ChatThought(text: "I should inspect the format first.")
        ))
        #expect(result.messages[2].seq == 21)
        #expect(result.messages[2].role == .agent)
        #expect(result.messages[2].kind == .prose(
            ChatProse(text: "I found the relevant entry.")
        ))
    }

    @Test("synthetic prompts cannot displace the first real user title candidate")
    func firstUserTitleCandidate() {
        let lines = [
            assistantLine(
                id: "a-preface",
                parentID: nil,
                content: [["type": "text", "text": "Assistant preface"]]
            ),
            userLine(id: "u-synthetic", text: "Continue automatically", synthetic: true),
            userLine(id: "u-real", text: "Implement mobile OMP history."),
            userLine(id: "u-later", text: "Then verify pagination."),
        ]

        let result = parser.parse(lines: lines, startingSeq: 0)
        let userProse = result.messages.compactMap { message -> String? in
            guard message.role == .user, case .prose(let prose) = message.kind else { return nil }
            return prose.text
        }

        #expect(userProse == ["Implement mobile OMP history.", "Then verify pagination."])
        #expect(result.messages.first(where: { $0.role == .user })?.seq == 2)
    }

    @Test("tool results arriving in a later parse update the original tool call")
    func toolPairingAcrossIncrementalParses() {
        let first = parser.parse(
            lines: [assistantLine(
                id: "a-tool",
                parentID: "u0000001",
                content: [[
                    "type": "toolCall",
                    "id": "call_read_1",
                    "name": "read",
                    "arguments": ["path": "Sources/App.swift"],
                ]]
            )],
            startingSeq: 30
        )

        #expect(first.messages.count == 1)
        #expect(first.messages[0].seq == 30)
        guard case .toolUse(let pendingTool) = first.messages[0].kind else {
            Issue.record("expected a generic tool call")
            return
        }
        #expect(pendingTool.toolName == "read")
        #expect(pendingTool.status == .running)
        #expect(first.state.pendingToolUses["call_read_1"]?.count == 1)

        let second = parser.parse(
            lines: [toolResultLine(
                id: "r0000001",
                parentID: "a-tool",
                toolCallID: "call_read_1",
                toolName: "read",
                texts: ["first line", "second line"]
            )],
            startingSeq: 31,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        let updated = second.updatedMessages[0]
        #expect(updated.id == first.messages[0].id)
        #expect(updated.seq == 30)
        guard case .toolUse(let completedTool) = updated.kind else {
            Issue.record("expected the paired tool call to remain a tool use")
            return
        }
        #expect(completedTool.output == "first line\nsecond line")
        #expect(completedTool.status == .succeeded)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("failed tool results mark the incrementally paired tool call failed")
    func failedToolResult() {
        let first = parser.parse(
            lines: [assistantLine(
                id: "a-failed-tool",
                parentID: "u0000001",
                content: [[
                    "type": "toolCall",
                    "id": "call_read_failed",
                    "name": "read",
                    "arguments": ["path": "Sources/Missing.swift"],
                ]]
            )],
            startingSeq: 40
        )
        let second = parser.parse(
            lines: [toolResultLine(
                id: "r-failed-tool",
                parentID: "a-failed-tool",
                toolCallID: "call_read_failed",
                toolName: "read",
                texts: ["File not found"],
                isError: true
            )],
            startingSeq: 41,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        guard case .toolUse(let tool) = second.updatedMessages[0].kind else {
            Issue.record("expected the failed result to update its tool use")
            return
        }
        #expect(tool.output == "File not found")
        #expect(tool.status == .failed)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("developer text is system prose and cannot become the user title candidate")
    func developerMessage() {
        let developer = messageLine(
            id: "d0000001",
            parentID: nil,
            message: [
                "role": "developer",
                "content": [[
                    "type": "text",
                    "text": "Follow the repository instructions.",
                ]],
                "timestamp": 1_771_235_263_000 as Int64,
            ]
        )
        let result = parser.parse(
            lines: [
                developer,
                userLine(id: "u-after-developer", text: "Implement the mobile history view."),
            ],
            startingSeq: 50
        )

        #expect(result.messages.count == 2)
        #expect(result.messages[0].id == "d0000001")
        #expect(result.messages[0].seq == 50)
        #expect(result.messages[0].role == .system)
        #expect(result.messages[0].kind == .prose(
            ChatProse(text: "Follow the repository instructions.")
        ))
        let titleCandidate = result.messages.first { $0.role == .user }
        #expect(titleCandidate?.seq == 51)
        #expect(titleCandidate?.kind == .prose(
            ChatProse(text: "Implement the mobile history view.")
        ))
    }

    @Test("malformed and unknown entries are skipped while line seq remains stable")
    func malformedUnknownAndStableSeq() {
        let unknownEntry = Self.json([
            "type": "future_entry",
            "id": "future-1",
            "parentId": NSNull(),
            "timestamp": "2026-02-16T10:20:31.000Z",
        ])
        let settingEntry = Self.json([
            "type": "thinking_level_change",
            "id": "thinking-setting",
            "parentId": NSNull(),
            "timestamp": "2026-02-16T10:20:32.000Z",
            "thinkingLevel": "high",
            "configured": "high",
        ])
        let unknownBlock = assistantLine(
            id: "a-unknown",
            parentID: nil,
            content: [["type": "future_content", "value": "ignored"]]
        )
        let lines = [
            "not-json {",
            unknownEntry,
            settingEntry,
            unknownBlock,
            userLine(id: "u-visible", text: "Visible after noise."),
        ]

        let result = parser.parse(lines: lines, startingSeq: 100)

        #expect(result.messages.count == 1)
        #expect(result.messages[0].id == "u-visible")
        #expect(result.messages[0].seq == 104)
        #expect(result.messages[0].kind == .prose(ChatProse(text: "Visible after noise.")))
    }

    private func headerLine() -> String {
        Self.json([
            "type": "session",
            "version": 3,
            "id": "019f0000-0000-7000-8000-000000000001",
            "timestamp": "2026-02-16T10:20:30.000Z",
            "cwd": "/work/anonymized-project",
            "title": "An anonymized session",
            "titleSource": "auto",
        ])
    }

    private func userLine(
        id: String,
        text: String,
        synthetic: Bool = false
    ) -> String {
        var message: [String: Any] = [
            "role": "user",
            "content": [["type": "text", "text": text]],
            "timestamp": 1_771_235_260_000 as Int64,
        ]
        if synthetic {
            message["synthetic"] = true
        }
        return messageLine(id: id, parentID: nil, message: message)
    }

    private func assistantLine(
        id: String,
        parentID: String?,
        content: [[String: Any]]
    ) -> String {
        messageLine(
            id: id,
            parentID: parentID,
            message: [
                "role": "assistant",
                "content": content,
                "api": "anthropic-messages",
                "provider": "anthropic",
                "model": "claude-sonnet-4-5",
                "usage": [
                    "input": 100,
                    "output": 20,
                    "cacheRead": 0,
                    "cacheWrite": 0,
                    "cost": [
                        "input": 0,
                        "output": 0,
                        "cacheRead": 0,
                        "cacheWrite": 0,
                        "total": 0,
                    ],
                ],
                "stopReason": content.contains { $0["type"] as? String == "toolCall" }
                    ? "toolUse"
                    : "stop",
                "timestamp": 1_771_235_261_000 as Int64,
            ]
        )
    }

    private func toolResultLine(
        id: String,
        parentID: String,
        toolCallID: String,
        toolName: String,
        texts: [String],
        isError: Bool = false
    ) -> String {
        messageLine(
            id: id,
            parentID: parentID,
            message: [
                "role": "toolResult",
                "toolCallId": toolCallID,
                "toolName": toolName,
                "content": texts.map { ["type": "text", "text": $0] },
                "details": [:] as [String: Any],
                "isError": isError,
                "timestamp": 1_771_235_262_000 as Int64,
            ]
        )
    }

    private func messageLine(
        id: String,
        parentID: String?,
        message: [String: Any]
    ) -> String {
        var entry: [String: Any] = [
            "type": "message",
            "id": id,
            "timestamp": "2026-02-16T10:21:00.000Z",
            "message": message,
        ]
        if let parentID {
            entry["parentId"] = parentID
        } else {
            entry["parentId"] = NSNull()
        }
        return Self.json(entry)
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
