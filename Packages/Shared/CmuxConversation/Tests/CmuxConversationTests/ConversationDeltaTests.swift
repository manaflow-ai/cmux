import Foundation
import Testing
@testable import CmuxConversation

@Suite struct ConversationDeltaTests {
    @Test func longResponseHasLinearWireSizeAndReplaysExactly() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let delta = String(repeating: "x", count: 100)
        var projection: ConversationItem?
        var bytes = 0
        for sequence in 1...1_000 {
            let item = ConversationItem(id: "answer", sequence: UInt64(sequence), kind: .message, role: "assistant", text: delta)
            let event = ConversationEvent(sessionID: "session", sequence: UInt64(sequence), generation: "generation", kind: .item, item: item, itemUpdate: .appendText)
            let data = try encoder.encode(event)
            bytes += data.count
            let replayed = try decoder.decode(ConversationEvent.self, from: data)
            projection = replayed.item?.applying(to: projection, mode: replayed.itemUpdate)
        }
        #expect(projection?.text == String(repeating: delta, count: 1_000))
        #expect(projection?.sequence == 1_000)
        #expect(bytes < 1_000_000)
        let final = ConversationItem(id: "answer", sequence: 1_001, kind: .message, text: "Authoritative completion")
        #expect(final.applying(to: projection, mode: nil).text == "Authoritative completion")
    }

    @Test func toolOutputDeltasRetainInputAndNativeStatus() {
        let initial = ConversationItem(id: "tool", sequence: 1, kind: .tool, tool: .init(toolID: "tool", name: "Command", input: .string("git status"), output: .string("first\n"), status: .running))
        let delta = ConversationItem(id: "tool", sequence: 2, kind: .tool, tool: .init(toolID: "tool", name: "Command", output: .string("second\n"), status: .running))
        let updated = delta.applying(to: initial, mode: .appendToolOutput)
        #expect(updated.tool?.output == .string("first\nsecond\n"))
        #expect(updated.tool?.input == .string("git status"))
        #expect(updated.tool?.status == .running)
        #expect(updated.sequence == 2)
    }

    @Test func deltasCannotAppendToAnotherItemsContent() {
        let previous = ConversationItem(id: "first", sequence: 1, kind: .message, text: "private")
        let next = ConversationItem(id: "second", sequence: 2, kind: .message, text: "new")
        #expect(next.applying(to: previous, mode: .appendText).text == "new")
    }
}
