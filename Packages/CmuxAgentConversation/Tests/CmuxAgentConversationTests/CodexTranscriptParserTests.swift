import Foundation
import Testing

@testable import CmuxAgentConversation

/// Behavioral tests for ``CodexTranscriptParser`` against a crafted rollout
/// fixture covering session_meta, a developer envelope, a user prompt,
/// reasoning, an assistant message, a function_call + function_call_output pair,
/// dropped `event_msg` duplicates, and dropped `token_count` noise.
@Suite struct CodexTranscriptParserTests {
    /// Loads a fixture `.jsonl` from the test bundle and splits it into lines.
    private func fixtureLines(_ name: String) throws -> [String] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")
        )
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test func parsesStructureAndSessionId() throws {
        let conversation = CodexTranscriptParser().parse(lines: try fixtureLines("codex-sample"))

        #expect(conversation.agentKind == .codex)
        #expect(conversation.sessionId == "sess-codex-1")
        #expect(conversation.seq == UInt64(conversation.messages.count))

        // developer permissions envelope is stripped; user prompt, reasoning,
        // assistant text, function_call, function_call_output, final assistant
        // text remain.
        let roles = conversation.messages.map(\.role)
        #expect(roles == [.user, .reasoning, .assistant, .assistant, .toolResult, .assistant])
    }

    @Test func eventMsgDuplicatesAreDropped() throws {
        let conversation = CodexTranscriptParser().parse(lines: try fixtureLines("codex-sample"))
        // The fixture's `user_message` and `agent_message` event_msg lines
        // duplicate the response_item message text. They must not appear as
        // extra messages: exactly one user prompt and the agent text comes from
        // the response_item, not the event_msg.
        let userMessages = conversation.messages.filter { $0.role == .user }
        #expect(userMessages.count == 1)
        #expect(userMessages.first?.blocks == [.text("List the files in the repo.")])

        let assistantTexts = conversation.messages
            .filter { $0.role == .assistant }
            .compactMap { message -> String? in
                guard case let .text(text) = message.blocks.first else { return nil }
                return text
            }
        #expect(assistantTexts == ["Listing files now.", "There are two files."])
    }

    @Test func functionCallAndOutputPairById() throws {
        let conversation = CodexTranscriptParser().parse(lines: try fixtureLines("codex-sample"))

        let call = try #require(conversation.messages.compactMap { message -> ToolUse? in
            for block in message.blocks {
                if case let .toolUse(use) = block { return use }
            }
            return nil
        }.first)
        #expect(call.id == "call_01")
        #expect(call.name == "exec_command")
        #expect(call.inputSummary == "ls")

        let result = try #require(conversation.messages.first { $0.role == .toolResult })
        #expect(result.toolCallID == "call_01")
        let toolResult = try #require(result.blocks.compactMap { block -> ToolResult? in
            if case let .toolResult(value) = block { return value }
            return nil
        }.first)
        #expect(toolResult.toolUseID == call.id)
        #expect(toolResult.blocks == [.text("README.md\nPackage.swift")])
    }

    @Test func reasoningCaptured() throws {
        let conversation = CodexTranscriptParser().parse(lines: try fixtureLines("codex-sample"))
        let reasoning = try #require(conversation.messages.first { $0.role == .reasoning })
        #expect(reasoning.blocks == [.reasoning("I'll run ls.")])
    }

    @Test func developerEnvelopeIsStripped() throws {
        let conversation = CodexTranscriptParser().parse(lines: try fixtureLines("codex-sample"))
        // The `<permissions instructions>` developer envelope is implementation
        // noise and must not appear as a conversation row.
        #expect(conversation.messages.allSatisfy { $0.role != .system })
        #expect(conversation.messages.allSatisfy { message in
            message.blocks.allSatisfy { block in
                if case let .text(text) = block { return !text.contains("permissions") }
                return true
            }
        })
    }

    @Test func nonEnvelopeSystemMessageMappedToSystem() {
        // A developer/system message that is NOT an envelope wrapper still
        // surfaces as a `.system` row.
        let lines = [
            #"{"type":"session_meta","payload":{"id":"s3"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"system","content":[{"type":"input_text","text":"You are now in plan mode."}]}}"#,
        ]
        let conversation = CodexTranscriptParser().parse(lines: lines)
        #expect(conversation.messages.count == 1)
        #expect(conversation.messages.first?.role == .system)
        #expect(conversation.messages.first?.blocks == [.text("You are now in plan mode.")])
    }

    @Test func unknownPayloadTypesAreSkipped() throws {
        let conversation = CodexTranscriptParser().parse(lines: try fixtureLines("codex-sample"))
        // `tool_search_call`, `turn_context`, and `token_count` produce nothing;
        // the developer permissions envelope is stripped. 6 messages remain.
        #expect(conversation.messages.count == 6)
    }

    @Test func stringFormMessageContentIsKept() {
        // A `response_item` message whose `content` is a plain string (not an
        // array of blocks) must still produce a turn — the parser drops the
        // duplicating `event_msg` fallback, so losing this would lose the turn.
        let lines = [
            #"{"type":"session_meta","payload":{"id":"s2"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":"Plain string answer."}}"#,
        ]
        let conversation = CodexTranscriptParser().parse(lines: lines)
        #expect(conversation.messages.count == 1)
        #expect(conversation.messages.first?.role == .assistant)
        #expect(conversation.messages.first?.blocks == [.text("Plain string answer.")])
    }
}
