import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-24, on missing images in his iPhone chat: "wer need to chase all these placeholders
/// doen and prevent them". An image the agent sent in its message decoded as empty text, and a
/// tool call's image output was read as text only (`outputText`), so neither drew anything.
@MainActor
@Suite struct ChatImagesDrawTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let at = Date(timeIntervalSince1970: 1_700_000_000)
    /// A 1x1 PNG.
    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    static func decode(_ json: String) throws -> ACPSessionUpdate {
        try JSONDecoder().decode(ACPSessionUpdate.self, from: Data(json.utf8))
    }

    static func imageChunk(_ messageId: String) throws -> ACPSessionUpdate {
        try decode(#"{"sessionUpdate":"agent_message_chunk","messageId":"\#(messageId)","content":{"type":"image","mimeType":"image/png","data":"\#(png)"}}"#)
    }

    @Test func anAgentMessageImageDecodesAsAPictureNotEmptyText() throws {
        let update = try Self.imageChunk("m1")
        guard case .toolCall(let call) = update else {
            Issue.record("an image in the agent's message decoded as \(update), which draws nothing")
            return
        }
        #expect(call.hasImages)
        #expect(call.images.first?.mimeType == "image/png")
        #expect(call.images.first?.data == Self.png)
        #expect(call.status == .completed)
        // Read again (a replay), the same record makes the same row.
        guard case .toolCall(let again) = try Self.imageChunk("m1") else { return }
        #expect(again.id == call.id)
    }

    @Test func aToolCallsImageOutputIsItsPictures() throws {
        let update = try Self.decode(#"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read shot.png","kind":"read","status":"completed","content":[{"type":"content","content":{"type":"image","mimeType":"image/png","data":"\#(Self.png)"}}]}"#)
        guard case .toolCall(let call) = update else { Issue.record("not a tool call: \(update)"); return }
        #expect(call.outputText.isEmpty)
        #expect(call.hasImages, "the call's image output is not seen, so its row draws nothing")
        #expect(call.images.count == 1)
    }

    /// The image row stands alone (never folded into a group's summary line, where it drew
    /// nothing), the same message's text around it keeps distinct rows, and the row is drawn by
    /// the view that paints its picture, not the native text-only tool line.
    @Test func aTranscriptWithAnImageDrawsItInItsOwnRow() throws {
        let store = AgentChatStore(source: Silent())
        let read = ACPToolCall(id: "r1", title: "Read a.swift", kind: .read, status: .completed)
        store.apply(.batch([
            .userMessage(text: "Show me", promptId: "p", turnId: "t", attachments: [], at: Self.at),
            .turnStarted(turnId: "t", at: Self.at),
            .update(.toolCall(read)),
            .update(.agentMessageChunk(text: "Here it is:", messageId: "m1")),
            .update(try Self.imageChunk("m1")),
            .update(.agentMessageChunk(text: "That's the screen.", messageId: "m1")),
            .turnResult(turnId: "t", status: .completed, errorText: nil, at: Self.at),
        ]))
        let rows = try #require(store.turns.last).rows
        let ids = rows.map(\.id)
        #expect(Set(ids).count == ids.count, "two rows share an id: \(ids)")
        let pictures = rows.compactMap { row -> ACPToolCall? in
            if case .tool(let call) = row, call.hasImages { return call }
            return nil
        }
        #expect(pictures.count == 1, "the image has no row of its own: \(ids)")
        let messages = rows.compactMap { row -> String? in
            if case .message(_, let markdown) = row { return markdown }
            return nil
        }
        #expect(messages == ["Here it is:", "That's the screen."])
        if let call = pictures.first {
            let row = ChatRow(id: "c-\(call.id)", turnID: "t", kind: .tool(call), gap: 0)
            #expect(!ChatNativeEligibility.drawsNatively(row, accessibilitySize: false, isOpen: { _ in nil }),
                    "the native tool line draws no picture")
        }
    }

    /// A tool call whose output holds a picture is not folded into a run of calls' one summary line.
    @Test func aCallWithAPictureIsNotGroupedAway() {
        var turn = AgentTurn(id: "t", prompt: "Go", promptAt: Self.at)
        turn.items = [
            .tool(ACPToolCall(id: "a", title: "Read a", kind: .read, status: .completed)),
            .tool(ACPToolCall(id: "b", title: "Screenshot", kind: .other, status: .completed,
                              content: [.content(.image(mimeType: "image/png", data: Self.png))])),
            .tool(ACPToolCall(id: "c", title: "Read c", kind: .read, status: .completed)),
        ]
        let standalone = turn.rows.contains { row in
            if case .tool(let call) = row { return call.id == "b" }
            return false
        }
        #expect(standalone, "the screenshot went into a group: \(turn.rows.map(\.id))")
    }
}
