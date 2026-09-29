import Foundation
import Testing
@testable import CmuxAcpmux

/// An in-memory daemon that records calls and lets the test push notifications.
private actor FakeAcpmuxAPI: AcpmuxSessionAPI {
    nonisolated let notifications: AsyncStream<JSONRPCNotification>
    nonisolated let feed: AsyncStream<JSONRPCNotification>.Continuation
    private(set) var attachCalls: [(String, Int?)] = []
    private(set) var prompts: [(text: String, promptId: String, delivery: String?)] = []
    let attachResult: AcpmuxAttachResult

    init(attachResult: AcpmuxAttachResult) {
        (notifications, feed) = AsyncStream.makeStream()
        self.attachResult = attachResult
    }

    func watch() async throws -> [AcpmuxSessionSummary] { [attachResult.session.summary] }
    func attach(sessionId: String, afterSeq: Int?, limit: Int) async throws -> AcpmuxAttachResult {
        attachCalls.append((sessionId, afterSeq))
        return attachResult
    }
    func events(sessionId: String, afterSeq: Int, limit: Int) async throws -> [AcpmuxEventRecord] { [] }
    func detach(sessionId: String) async throws {}
    func newSession(harness: String?, cwd: String?) async throws -> String { "new" }
    func prompt(sessionId: String, text: String, promptId: String, delivery: String?) async throws -> JSONValue {
        prompts.append((text, promptId, delivery))
        return .object(["stopReason": .string("end_turn")])
    }
    func cancel(sessionId: String) async throws {}
    func respondToPermission(sessionId: String, permissionId: String, optionId: String?) async throws {}
    func steerQueued(sessionId: String, promptId: String) async throws {}
    func removeQueued(sessionId: String, promptId: String) async throws {}
    func harnessCatalog() async throws -> AcpmuxHarnessCatalog { AcpmuxHarnessCatalog() }
    func setModel(sessionId: String, modelId: String) async throws {}
    func close() async { feed.finish() }
}

private struct FakeConnector: AcpmuxConnecting {
    let api: FakeAcpmuxAPI
    func connect() async throws -> any AcpmuxSessionAPI { api }
}

@MainActor
struct AcpmuxChatSessionModelTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 where !condition() {
            await Task.yield()
        }
    }

    @Test func attachesRestoredSessionAndStreamsLiveUpdates() async throws {
        let attach = try FixtureLoader().fakeAttach()
        let api = FakeAcpmuxAPI(attachResult: attach)
        let model = AcpmuxChatSessionModel(
            connector: FakeConnector(api: api),
            sessionId: attach.session.summary.sessionId,
            workingDirectory: nil
        )
        model.start()
        await waitUntil { model.rows.count == 11 }
        #expect(model.connectionState == .connected)
        #expect(model.rows.count == 11)

        // A live chunk for the next turn streams into a new assistant row.
        api.feed.yield(JSONRPCNotification(method: "_acpmux/event", params: .object([
            "sessionId": .string(attach.session.summary.sessionId), "seq": .number(43), "at": .number(1),
            "dir": .string("mux"), "kind": .string("turn_started"), "msg": .object(["prompt": .string("x")]),
        ])))
        api.feed.yield(JSONRPCNotification(method: "session/update", params: .object([
            "sessionId": .string(attach.session.summary.sessionId),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("live")]),
            ]),
            "_meta": .object(["acpmux": .object(["seq": .number(44), "at": .number(2)])]),
        ])))
        await waitUntil { model.rows.last?.content == .assistant(text: "live", isStreaming: true) }
        #expect(model.rows.last?.content == .assistant(text: "live", isStreaming: true))
        #expect(model.isWorking)
        model.stop()
    }

    @Test func sendShowsLocalEchoAndPromptsDaemon() async throws {
        var attach = try FixtureLoader().fakeAttach()
        attach.events = []
        let api = FakeAcpmuxAPI(attachResult: attach)
        let model = AcpmuxChatSessionModel(
            connector: FakeConnector(api: api),
            sessionId: attach.session.summary.sessionId,
            workingDirectory: nil
        )
        model.start()
        await waitUntil { model.connectionState == .connected && model.summary != nil }
        let rowID = model.send("  hello  ")
        #expect(rowID != nil)
        #expect(model.rows.first?.content == .user(TranscriptUserMessage(text: "hello", isPending: true)))
        var prompts: [(text: String, promptId: String, delivery: String?)] = []
        for _ in 0..<2_000 where prompts.isEmpty {
            prompts = await api.prompts
            await Task.yield()
        }
        #expect(prompts.map(\.text) == ["hello"])
        #expect(prompts.first?.delivery == nil)
        model.stop()
    }
}
