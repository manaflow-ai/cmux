import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// New side chat and `/side [prompt]` on a Cloud chat ("whatever works on a local chat should work
/// on a Cloud chat", cmuxterm-hq#7856): the page's `_acpmux/side_chat` goes to this chat's daemon
/// (`agent-session-side-v1`) with the fork's boundary and prompt, the side chat is noted as this
/// chat's child so the host opens it beside the chat, the handshake names `side_chat` only where the
/// daemon serves it, and an observer never opens one.
@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxSideChatTests {
    nonisolated final class FakeClient: AgentSessionRemoteClient {
        let calls = Mutex<[String]>([])
        let isReadOnly: Bool
        let served: Bool

        init(readOnly: Bool = false, served: Bool = true) {
            isReadOnly = readOnly
            self.served = served
        }

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            Data(#"{"session":{"sessionId":"acp_1"},"events":[],"hasMore":false,"lastSeq":3}"#.utf8)
        }

        func events(_ page: AgentSessionPage) async throws -> Data { Data(#"{"events":[],"hasMore":false,"lastSeq":3}"#.utf8) }
        func prompt(id: String, text: String) async throws -> Data { Data(#"{}"#.utf8) }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                        personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}
        func setModel(_ modelId: String) async throws -> Data { Data("{}".utf8) }
        func setMode(_ modeId: String) async throws -> Data { Data("{}".utf8) }
        func setConfig(id configId: String, value: String) async throws -> Data { Data("{}".utf8) }

        func servesSide() async -> Bool { served }

        func side(throughSeq: Int?, prompt: String?, promptID: String) async throws -> String {
            calls.withLock { $0.append("\(throughSeq.map(String.init) ?? "live") \(prompt ?? "-")") }
            return "acp_side_\(calls.withLock { $0.count })"
        }
    }

    typealias Frames = RemoteAcpmuxObserverTests.Frames

    static func wire(_ client: FakeClient, host: String) async throws -> (RemoteAcpmuxWire, Frames) {
        let frames = Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "sub", host: host)
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        return (wire, frames)
    }

    static func error(_ frames: Frames, _ id: Int) -> [String: Any]? {
        (frames.reply(id)?["error"] as? [String: Any])?["data"] as? [String: Any]
    }

    @Test func theHandshakeNamesTheFeatureOnlyWhereTheDaemonServesIt() async throws {
        for served in [true, false] {
            let (wire, frames) = try await Self.wire(FakeClient(served: served), host: "side-handshake")
            wire.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#) { _ in }
            try await Self.waitUntil { frames.reply(1) != nil }
            let acpmux = ((frames.reply(1)?["result"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
            #expect(((acpmux?["features"] as? [String])?.contains("side_chat") ?? false) == served)
        }
    }

    @Test func aNewChatNamesTheFeatureFromItsMachinesDaemon() async throws {
        let start: RemoteAcpmuxWire.Start = { _, _, _ in throw CancellationError() }
        for served in [true, false] {
            let frames = Frames()
            let wire = RemoteAcpmuxWire(start: start, servesSide: served)
            try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
            wire.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#) { _ in }
            try await Self.waitUntil { frames.reply(1) != nil }
            let acpmux = ((frames.reply(1)?["result"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
            #expect(((acpmux?["features"] as? [String])?.contains("side_chat") ?? false) == served)
        }
    }

    @Test func aSideChatOpensOnThisChatsMachineAsItsChild() async throws {
        let client = FakeClient()
        let host = "side-\(UUID().uuidString)"
        let (wire, frames) = try await Self.wire(client, host: host)
        wire.send(#"{"jsonrpc":"2.0","id":2,"method":"_acpmux/side_chat","params":{"sessionId":"sub","throughSeq":4}}"#) { _ in }
        try await Self.waitUntil { frames.reply(2) != nil }
        wire.send(#"{"jsonrpc":"2.0","id":3,"method":"_acpmux/side_chat","params":{"sessionId":"sub","live":true,"prompt":"try a queue"}}"#) { _ in }
        try await Self.waitUntil { frames.reply(3) != nil }
        #expect((frames.reply(2)?["result"] as? [String: Any])?["sessionId"] as? String == "acp_side_1")
        #expect((frames.reply(3)?["result"] as? [String: Any])?["sessionId"] as? String == "acp_side_2")
        #expect(client.calls.withLock { $0 } == ["4 -", "live try a queue"])
        let parents = await MainActor.run {
            ["acp_side_1", "acp_side_2"].map { RemoteAgentSessionLinks.shared.parent(of: $0, host: host) }
        }
        #expect(parents == ["acp_1", "acp_1"])
    }

    @Test func anotherChatOrABadBoundaryOpensNothing() async throws {
        let client = FakeClient()
        let (wire, frames) = try await Self.wire(client, host: "side-refused")
        for frame in [
            #"{"jsonrpc":"2.0","id":2,"method":"_acpmux/side_chat","params":{"sessionId":"acp_other","throughSeq":4}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"_acpmux/side_chat","params":{"sessionId":"sub"}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"_acpmux/side_chat","params":{"sessionId":"sub","throughSeq":0}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"_acpmux/side_chat","params":{"sessionId":"sub","throughSeq":6.5}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"_acpmux/side_chat","params":{"sessionId":"sub","throughSeq":4,"live":true}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/side_chat","params":{"sessionId":"sub","throughSeq":true}}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"_acpmux/side_chat","params":{"sessionId":"sub","live":true,"prompt":7}}"#,
        ] {
            wire.send(frame) { _ in }
        }
        try await Self.waitUntil { (2...8).allSatisfy { frames.reply($0) != nil } }
        for id in 2...8 { #expect(Self.error(frames, id)?["code"] as? String == RemoteAcpmuxWire.unsupported, "\(id)") }
        #expect(client.calls.withLock { $0 }.isEmpty)
    }

    @Test func anObserverNeverOpensASideChat() async throws {
        let client = FakeClient(readOnly: true)
        let (wire, frames) = try await Self.wire(client, host: "side-observer")
        wire.send(#"{"jsonrpc":"2.0","id":2,"method":"_acpmux/side_chat","params":{"sessionId":"sub","live":true}}"#) { _ in }
        try await Self.waitUntil { frames.reply(2) != nil }
        #expect(Self.error(frames, 2)?["code"] as? String == RemoteAcpmuxWire.readOnly)
        #expect(client.calls.withLock { $0 }.isEmpty)
    }

    private static func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
