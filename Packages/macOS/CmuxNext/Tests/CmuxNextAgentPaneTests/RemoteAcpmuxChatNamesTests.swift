import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// cmux#55668: a Cloud chat's tab and workspace never took its title, because nothing of this Mac learned it. The
/// chat's page reads its summary over its remote wire (the attach, then each change), and the wire hands this chat's
/// summary, never a child's, to the app with the tab's host (``RemoteAcpmuxWire/ChatNoted``).
@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxChatNamesTests {
    nonisolated final class FakeClient: AgentSessionRemoteClient {
        let isReadOnly: Bool
        init(readOnly: Bool = false) { isReadOnly = readOnly }
        let handler = Mutex<(@Sendable (AgentSessionRemoteEvent) -> Void)?>(nil)

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            self.handler.withLock { $0 = handler }
            return Data(#"{"session":{"sessionId":"acp_1","title":"Fix the flaky test","titleSource":"generated"},"events":[],"hasMore":false,"lastSeq":3}"#.utf8)
        }

        func events(_ page: AgentSessionPage) async throws -> Data { Data(#"{"events":[],"hasMore":false,"lastSeq":3}"#.utf8) }
        func prompt(id: String, text: String) async throws -> Data { Data("{}".utf8) }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                        personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}
        func setModel(_ modelId: String) async throws -> Data { Data("{}".utf8) }
        func setMode(_ modeId: String) async throws -> Data { Data("{}".utf8) }
        func setConfig(id configId: String, value: String) async throws -> Data { Data("{}".utf8) }
    }

    typealias Frames = RemoteAcpmuxObserverTests.Frames

    /// What ``RemoteAcpmuxWire/ChatNoted`` heard: each noted summary's host, `sessionId` and `title`.
    nonisolated final class Noted: Sendable {
        let notes = Mutex<[String]>([])
        var all: [String] { notes.withLock { $0 } }
        var chatNoted: RemoteAcpmuxWire.ChatNoted {
            { [self] summary, host in
                self.notes.withLock { $0.append("\(host) \(summary["sessionId"] as? String ?? "?") \(summary["title"] as? String ?? "-")") }
            }
        }
    }

    @Test func theAttachAndThisChatsChangesNoteItsSummaryWithTheTabsHost() async throws {
        let noted = Noted(), client = FakeClient(), frames = Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "sub", host: "install:vm", chatNoted: noted.chatNoted)
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/attach","params":{"sessionId":"sub"}}"#) { _ in }
        try await Self.waitUntil { noted.all == ["install:vm acp_1 Fix the flaky test", "install:vm sub Fix the flaky test"] }

        // The chat's own change is noted; a child's (another session the chat started there) is not.
        let push = { (id: String, title: String) in
            let change: [String: Any] = ["sessionId": id, "kind": "updated", "session": ["sessionId": id, "title": title, "titleSource": "generated"]]
            let data = try JSONSerialization.data(withJSONObject: change)
            client.handler.withLock { $0 }?(.changed(data))
        }
        try push("acp_child", "A child")
        try push("acp_1", "Fix the flaky login test")
        try await Self.waitUntil { noted.all.count == 4 }
        // The tab records the chat as "sub": it is noted under acpmux's id and under the tab's name.
        #expect(noted.all == ["install:vm acp_1 Fix the flaky test", "install:vm sub Fix the flaky test",
                              "install:vm acp_1 Fix the flaky login test", "install:vm sub Fix the flaky login test"])
    }

    /// A Cloud machine's own tab records its chat under the daemon's store host (`registry:<id>`): the wire notes it there
    /// too, as it notes the chat's links, so that tab reads the title whichever host the tab's route names.
    @Test func theChatIsNotedUnderTheDaemonsStoreHostToo() async throws {
        let noted = Noted(), frames = Frames()
        let wire = RemoteAcpmuxWire(client: FakeClient(), session: "acp_1", host: "install:vm", linksAlias: "registry:vm",
                                    chatNoted: noted.chatNoted)
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/attach","params":{"sessionId":"acp_1"}}"#) { _ in }
        try await Self.waitUntil { noted.all.count == 2 }
        #expect(noted.all == ["install:vm acp_1 Fix the flaky test", "registry:vm acp_1 Fix the flaky test"])
    }

    @Test func aHostlessWireNotesNothing() async throws {
        let noted = Noted(), frames = Frames()
        let wire = RemoteAcpmuxWire(client: FakeClient(), session: "sub", chatNoted: noted.chatNoted)
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/attach","params":{"sessionId":"sub"}}"#) { _ in }
        try await Self.waitUntil { frames.reply(1) != nil }
        #expect(noted.all.isEmpty)
    }

    /// A Cloud VM names this Mac's tabs only while the Cloud API says it is the person's own: a teammate's VM (or one whose
    /// owner answer is gone) notes nothing, and a read-only view of a chat never does.
    @Test func onlyThePersonsOwnMachineInAnAttachNotesTheChat() async throws {
        for (owned, readOnly, notes) in [(true, false, 2), (false, false, 0), (true, true, 0)] {
            let noted = Noted(), frames = Frames()
            let wire = RemoteAcpmuxWire(client: FakeClient(readOnly: readOnly), session: "sub", host: "install:vm",
                                        chatNoted: noted.chatNoted, chatOwned: { owned })
            try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
            wire.send(#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/attach","params":{"sessionId":"sub"}}"#) { _ in }
            try await Self.waitUntil { frames.reply(1) != nil }
            if notes > 0 { try await Self.waitUntil { noted.all.count == notes } } else { try await Task.sleep(for: .milliseconds(100)) }
            #expect(noted.all.count == notes, "owned \(owned), read-only \(readOnly)")
        }
    }

    /// Only a summary's name fields cross to the app: never its icon bytes or any other field, and each is capped.
    @Test func onlyTheNameFieldsAreHandedOn() {
        let names = RemoteAcpmuxWire.chatNames(["sessionId": "acp_1", "title": String(repeating: "t", count: 10_000), "icon": ["kind": "image", "data": "AAAA"],
                                                "formerNames": (0..<50).map { "n\($0)" }, "cwd": "/Users/x", "lastMessage": "secret"])
        #expect(Set(names.keys) == ["sessionId", "title", "formerNames"])
        #expect((names["title"] as? String)?.count == 4096)
        #expect((names["formerNames"] as? [String])?.count == 8)
    }

    private static func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
