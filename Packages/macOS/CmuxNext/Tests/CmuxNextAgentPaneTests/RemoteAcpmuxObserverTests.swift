import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxObserverTests {
    nonisolated final class FakeClient: AgentSessionRemoteClient {
        let calls = Mutex<[String]>([])
        let handler = Mutex<(@Sendable (AgentSessionRemoteEvent) -> Void)?>(nil)
        let isReadOnly = true

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            calls.withLock { $0.append("attach") }
            self.handler.withLock { $0 = handler }
            return Data(#"{"session":{"sessionId":"acp_1"},"events":[],"hasMore":false,"lastSeq":3}"#.utf8)
        }

        func events(_ page: AgentSessionPage) async throws -> Data {
            calls.withLock { $0.append("events") }
            return Data(#"{"events":[],"hasMore":false,"lastSeq":3}"#.utf8)
        }

        func prompt(id: String, text: String) async throws -> Data {
            calls.withLock { $0.append("prompt") }
            return Data(#"{}"#.utf8)
        }

        func cancel() async throws { calls.withLock { $0.append("cancel") } }

        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                        personDecision: String?) async throws {
            calls.withLock { $0.append("permission") }
        }

        func detach() async { calls.withLock { $0.append("detach") } }
        func close() async { calls.withLock { $0.append("close") } }

        func push(_ event: AgentSessionRemoteEvent) { handler.withLock { $0 }?(event) }
    }

    nonisolated final class Frames: Sendable {
        // The lock holds only the frames' text, which is Sendable; each read decodes outside it.
        let texts = Mutex<[String]>([])
        let closes = Mutex<[String]>([])

        func append(_ text: String) { texts.withLock { $0.append(text) } }

        func objects() -> [[String: Any]] {
            texts.withLock { $0 }.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }

        func reply(_ id: Int) -> [String: Any]? { objects().first { $0["id"] as? Int == id } }
        func notifications(_ method: String) -> [[String: Any]] { objects().filter { $0["method"] as? String == method } }
    }

    static func wire() async throws -> (RemoteAcpmuxWire, FakeClient, Frames) {
        let client = FakeClient()
        let frames = Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "sub")
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, reason in frames.closes.withLock { $0.append(reason) } })
        return (wire, client, frames)
    }

    static func send(_ wire: RemoteAcpmuxWire, _ frame: String) {
        wire.send(frame) { _ in }
    }

    @Test func observerPushesRecordsPermissionsAndChangesButDeniesMutationsLocally() async throws {
        let (wire, client, frames) = try await Self.wire()
        Self.send(wire, #"{"jsonrpc":"2.0","id":1,"method":"_acpmux/attach","params":{"sessionId":"sub"}}"#)
        try await waitUntil { frames.reply(1) != nil }

        client.push(.record(Data(#"{"sessionId":"acp_1","seq":4}"#.utf8)))
        client.push(.permission(Data(#"{"sessionId":"acp_1","permissionId":"perm_1"}"#.utf8)))
        client.push(.changed(Data(#"{"sessionId":"acp_1","kind":"status"}"#.utf8)))
        try await waitUntil {
            frames.notifications("_acpmux/event").count == 1
                && frames.notifications("_acpmux/permission_pending").count == 1
                && frames.notifications("_acpmux/session_changed").count == 1
        }

        Self.send(wire, #"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"sub","prompt":[{"type":"text","text":"hi"}]}}"#)
        Self.send(wire, #"{"jsonrpc":"2.0","id":3,"method":"session/cancel","params":{"sessionId":"sub"}}"#)
        Self.send(wire, #"{"jsonrpc":"2.0","id":4,"method":"_acpmux/permission_respond","params":{"sessionId":"sub","permissionId":"perm_1","optionId":"allow"}}"#)
        try await waitUntil { frames.reply(2) != nil && frames.reply(3) != nil && frames.reply(4) != nil }
        for id in 2...4 {
            let reply = try #require(frames.reply(id))
            let error = try #require(reply["error"] as? [String: Any])
            let data = try #require(error["data"] as? [String: Any])
            #expect(data["code"] as? String == RemoteAcpmuxWire.readOnly)
        }
        #expect(client.calls.withLock { $0 } == ["attach"])
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
