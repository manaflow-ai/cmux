import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The shared page host's chat tails stay in ``JSONValue``: the tail is the chat's whole last read,
/// and walking it into Foundation and back on the main actor (`AgentPageProvider.tail`) hung the
/// app 26 s (cmuxterm-hq#19028). The answers are the ones the Foundation path gave.
@Suite(.serialized)
@MainActor
struct ChatTailJSONPathTests {
    private static func reset() {
        AgentPaneTailCache.shared.clear()
        AgentPaneTailCache.shared.resume()
    }

    private static func page(_ count: Int, mark: String = "a") -> JSONValue {
        JSONValue(foundation: ChatTailCacheTests.tail(count, mark: mark))!
    }

    private static func call(_ provider: AgentPageProvider, _ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await provider.call(AgentPageOps.namespace + method, params: params, context: ChatTailCacheTests.context)
    }

    @Test func thePageHostKeepsAndReadsTheTailItWasHanded() async throws {
        Self.reset()
        defer { Self.reset() }
        let provider = AgentPageProvider { _ in nil }
        let tail = Self.page(3)
        #expect(try await Self.call(provider, "chat.tail", .object(["sessionId": .string("s-1"), "tail": tail])) == .null)
        // The very value handed over, not a Foundation copy of it.
        #expect(AgentPaneTailCache.shared.tail(for: "s-1") == tail)
        #expect(try await Self.call(provider, "chat.tail.get", .object(["sessionId": .string("s-1")])) == tail)

        // A hover's hand-over keeps only a newer tail; a forget drops it.
        let older = Self.page(2, mark: "hover")
        _ = try await Self.call(provider, "chat.tail", .object(["sessionId": .string("s-1"), "tail": older, "ifNewer": .bool(true)]))
        #expect(AgentPaneTailCache.shared.tail(for: "s-1") == tail)
        _ = try await Self.call(provider, "chat.tail", .object(["sessionId": .string("s-1")]))
        #expect(AgentPaneTailCache.shared.tail(for: "s-1") == nil)
        #expect(try await Self.call(provider, "chat.tail.get", .object(["sessionId": .string("s-1")])) == .null)
    }

    @Test func bothHostsAnswerTheSameOpsAlike() async throws {
        Self.reset()
        defer { Self.reset() }
        let provider = AgentPageProvider { _ in nil }
        _ = ChatTailCacheTests.value(ChatTailCacheTests.bridge("chat.tail", ["sessionId": "s-2", "tail": ChatTailCacheTests.tail(4)]))
        let page = try await Self.call(provider, "chat.tail.get", .object(["sessionId": .string("s-2")]))
        let bridged = await AgentPaneTailCache.reply(to: "chat.tail.get", params: ["sessionId": "s-2"], host: nil)
        let answered = try #require(ChatTailCacheTests.value(bridged))
        #expect(JSONValue(foundation: answered) == page)
        #expect(ChatTailCacheTests.seqs(page.foundationObject) == [1, 2, 3, 4])

        // Refusals keep their code on both.
        let refused = AgentPaneTailCache.reply(to: "chat.tail.forget", params: ["sessionId": "s-2"])
        #expect((refused["error"] as? [String: Any])?["code"] as? String == "native.invalid_request")
        #expect(AgentPaneTailCache.answer(to: "chat.tail.forget", params: .object(["sessionId": .string("s-2")]))
            == .refused("No such chat tail request"))
        await #expect(throws: PageError.self) {
            try await Self.call(provider, "chat.tail", .object(["tail": Self.page(1)]))
        }
    }

    @Test func aSubagentPanesHandOverIsKeptAndNotPassedToTheModel() {
        Self.reset()
        defer { Self.reset() }
        let tail = Self.page(3)
        let params: JSONValue = .object(["subagent": .string("a1"), "focus": .bool(true),
                                         "handOver": .object(["sessionId": .string("s-3"), "tail": tail])])
        AgentPaneTailCache.keepHandOver(of: "chat.subagentPane", params: params, pageGeneration: AgentPaneTailCache.shared.generation &+ 1)
        #expect(AgentPaneTailCache.shared.tail(for: "s-3") == nil, "a page from before a sign-out hands nothing over")
        AgentPaneTailCache.keepHandOver(of: "chat.subagentPane", params: params, pageGeneration: AgentPaneTailCache.shared.generation)
        #expect(AgentPaneTailCache.shared.tail(for: "s-3") == tail)

        let request = AgentPageProvider.withoutHandOver(params, of: "chat.subagentPane")
        #expect(request == .object(["subagent": .string("a1"), "focus": .bool(true)]))
        #expect(AgentPaneRequest(body: ["method": "chat.subagentPane", "params": request.foundationObject])
            == AgentPaneRequest(body: ["method": "chat.subagentPane", "params": params.foundationObject]))
        #expect(AgentPageProvider.withoutHandOver(.object(["a": .null]), of: "chat.subagentPane") == .object(["a": .null]))
        // Only a subagent pane's hand-over is the store's: another method's `handOver` reaches its model.
        #expect(AgentPageProvider.withoutHandOver(params, of: "chat.openTab") == params)
    }

    @Test func aBridgedMemberThatIsNotJSONLeavesTheTailItsOwn() throws {
        Self.reset()
        defer { Self.reset() }
        let params: [String: Any] = ["sessionId": "s-4", "tail": ChatTailCacheTests.tail(3), "stray": Date()]
        _ = ChatTailCacheTests.value(AgentPaneTailCache.reply(to: "chat.tail", params: params))
        #expect(AgentPaneTailCache.shared.tail(for: "s-4") == Self.page(3))
        let read = AgentPaneTailCache.reply(to: "chat.tail.get", params: ["sessionId": "s-4", "stray": Date()])
        #expect(ChatTailCacheTests.seqs(ChatTailCacheTests.value(read)) == [1, 2, 3])
    }
}
