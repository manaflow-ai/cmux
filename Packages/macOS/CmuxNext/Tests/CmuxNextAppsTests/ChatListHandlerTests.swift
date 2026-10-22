import CmuxNextApps
import Testing

/// `chat.list`: apps read every agent chat in the Priority view's order, with the fields a
/// Priority View app draws; other `chat.*` ops stay unsupported.
struct ChatListHandlerTests {
    private let ranked = [
        AppChatSummary(id: "s1", title: "Fix login", project: "web", state: .needsYou, unread: true),
        AppChatSummary(id: "s2", title: "Docs", machine: "cmux17", state: .done, unread: true, pinned: true),
        AppChatSummary(id: "s3", title: "Refactor", state: .working),
    ]

    @Test func listsTheChatsInRankOrderWithTheirFields() async throws {
        let handler = ChatListHandler(chats: { [ranked] in ranked })
        #expect(handler.families == ["chat"])
        let reply = try await handler.handle(.init(app: "cmux/priority-view", op: "chat.list", params: [:], origin: "script"))
        let chats = try #require(reply["chats"]?.arrayValue)
        #expect(chats.compactMap { $0["id"]?.stringValue } == ["s1", "s2", "s3"])
        #expect(chats.compactMap { $0["state"]?.stringValue } == ["needs_you", "done", "working"])
        #expect(chats[0]["project"]?.stringValue == "web")
        #expect(chats[0]["machine"] == .null)
        #expect(chats[1]["machine"]?.stringValue == "cmux17")
        #expect(chats[1]["pinned"] == .bool(true))
        #expect(chats[2]["unread"] == .bool(false))
    }

    @Test func otherChatOpsStayUnsupported() async {
        let handler = ChatListHandler(chats: { [] })
        do throws(AppHostCapabilityError) {
            _ = try await handler.handle(.init(app: "cmux/priority-view", op: "chat.delete", params: [:], origin: "user"))
            Issue.record("chat.delete was answered")
        } catch {
            #expect(error.code == "operation.unsupported")
        }
    }
}
