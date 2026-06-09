import Foundation
import Testing

@testable import CmuxAgentConversation

/// Behavioral tests for ``ClaudeCodeTranscriptParser`` against a crafted
/// transcript fixture covering a user prompt, an assistant reasoning + text +
/// tool_use turn, a tool_result, an unknown line type, and malformed JSON.
@Suite struct ClaudeCodeTranscriptParserTests {
    /// Loads a fixture `.jsonl` from the test bundle and splits it into lines.
    private func fixtureLines(_ name: String) throws -> [String] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")
        )
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test func parsesStructureAndSessionId() throws {
        let conversation = ClaudeCodeTranscriptParser().parse(lines: try fixtureLines("claude-sample"))

        #expect(conversation.agentKind == .claudeCode)
        #expect(conversation.sessionId == "sess-claude-1")
        #expect(conversation.seq == UInt64(conversation.messages.count))

        // user prompt, reasoning, assistant text+tool_use, tool_result, final assistant text.
        let roles = conversation.messages.map(\.role)
        #expect(roles == [.user, .reasoning, .assistant, .toolResult, .assistant])
    }

    @Test func userPromptText() throws {
        let conversation = ClaudeCodeTranscriptParser().parse(lines: try fixtureLines("claude-sample"))
        let first = try #require(conversation.messages.first)
        #expect(first.role == .user)
        #expect(first.blocks == [.text("List the files in the repo.")])
    }

    @Test func assistantToolUseIsCaptured() throws {
        let conversation = ClaudeCodeTranscriptParser().parse(lines: try fixtureLines("claude-sample"))
        let assistant = try #require(conversation.messages.first { $0.role == .assistant && $0.blocks.contains { if case .toolUse = $0 { true } else { false } } })

        let toolUse = try #require(assistant.blocks.compactMap { block -> ToolUse? in
            if case let .toolUse(use) = block { return use }
            return nil
        }.first)
        #expect(toolUse.id == "toolu_01")
        #expect(toolUse.name == "Bash")
        #expect(toolUse.inputSummary == "ls")
        #expect(toolUse.inputJSON.contains("\"command\":\"ls\""))
    }

    @Test func reasoningSplitIntoOwnMessage() throws {
        let conversation = ClaudeCodeTranscriptParser().parse(lines: try fixtureLines("claude-sample"))
        let reasoning = try #require(conversation.messages.first { $0.role == .reasoning })
        #expect(reasoning.blocks == [.reasoning("I should run ls.")])
    }

    @Test func toolResultPairsToCallById() throws {
        let conversation = ClaudeCodeTranscriptParser().parse(lines: try fixtureLines("claude-sample"))
        let result = try #require(conversation.messages.first { $0.role == .toolResult })

        // The call id is preserved on the message AND inside the result node,
        // so a view projection can pair call to result without pre-merging.
        #expect(result.toolCallID == "toolu_01")
        let toolResult = try #require(result.blocks.compactMap { block -> ToolResult? in
            if case let .toolResult(value) = block { return value }
            return nil
        }.first)
        #expect(toolResult.toolUseID == "toolu_01")
        #expect(toolResult.isError == false)
        #expect(toolResult.blocks == [.text("README.md\nPackage.swift")])

        // Call comes before result in transcript order.
        let callIndex = try #require(conversation.messages.firstIndex { $0.blocks.contains { if case .toolUse = $0 { true } else { false } } })
        let resultIndex = try #require(conversation.messages.firstIndex { $0.role == .toolResult })
        #expect(callIndex < resultIndex)
    }

    @Test func unknownTypesAndMalformedLinesAreSkipped() throws {
        let conversation = ClaudeCodeTranscriptParser().parse(lines: try fixtureLines("claude-sample"))
        // The fixture contains a `summary`, an unknown future type, and an
        // invalid-JSON line; none of them produce messages.
        #expect(conversation.messages.count == 5)
        #expect(conversation.messages.allSatisfy { !$0.blocks.isEmpty })
    }
}
