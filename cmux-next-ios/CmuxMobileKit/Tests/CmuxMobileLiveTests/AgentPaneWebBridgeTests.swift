import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The phone hosts the Mac's React agent pane (`pane.js`) against acpmux over its link: the page's
/// bridge calls (`ready`, `transport.open/send/close`) map onto one `acpmux` channel per connection.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AgentPaneWebBridgeTests {
    @Test func handshakeNamesTheBridgeTransportAndTheSession() async throws {
        let bridge = AgentPaneWebBridge(sessionID: "s1", machineName: "Mac", openChannel: { EchoAcpmuxChannel() }, evaluate: { _ in })
        let reply = await bridge.handle(["id": "a", "method": "ready", "params": [:]])
        #expect(reply["ok"] as? Bool == true)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["transport"] as? String == "acpmux-bridge")
        #expect(value["protocolVersion"] as? Int == AgentPaneWebBridge.protocolVersion)
        #expect(value["sessionId"] as? String == "s1")
        #expect(value["endpoint"] == nil && value["token"] == nil)
    }

    @Test func pageFramesReachAcpmuxAndItsRepliesComeBackAsPushes() async throws {
        let channel = EchoAcpmuxChannel()
        var scripts: [String] = []
        let bridge = AgentPaneWebBridge(sessionID: nil, machineName: nil, openChannel: { channel }, evaluate: { scripts.append($0) })
        let open = await bridge.handle(["method": "transport.open"])
        let connection = try #require((open["value"] as? [String: Any])?["connection"] as? Int)
        let frame = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let sent = await bridge.handle(["method": "transport.send", "params": ["connection": connection, "frames": [frame]]])
        #expect(sent["ok"] as? Bool == true)
        #expect(channel.sent == [frame])
        for _ in 0..<200 where scripts.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let push = try #require(scripts.first)
        #expect(push.hasPrefix("window.cmuxAcpmuxTransport?.receive("))
        #expect(push.contains(#""connection":\#(connection)"#))
        #expect(push.contains(#"\"id\":1"#) && push.contains(#"\"result\""#))
        #expect(push.contains(#""seq":1"#))
    }

    @Test func aClosedConnectionRefusesSendsAsStale() async throws {
        let bridge = AgentPaneWebBridge(sessionID: nil, machineName: nil, openChannel: { EchoAcpmuxChannel() }, evaluate: { _ in })
        let open = await bridge.handle(["method": "transport.open"])
        let connection = try #require((open["value"] as? [String: Any])?["connection"] as? Int)
        _ = await bridge.handle(["method": "transport.close", "params": ["connection": connection]])
        #expect(bridge.openConnections == 0)
        let sent = await bridge.handle(["method": "transport.send", "params": ["connection": connection, "frames": ["{}"]]])
        #expect((sent["error"] as? [String: Any])?["code"] as? String == "transport.stale_connection")
    }

    @Test func theMacClosingTheChannelClosesThePageSocket() async throws {
        let channel = EchoAcpmuxChannel()
        var scripts: [String] = []
        let bridge = AgentPaneWebBridge(sessionID: nil, machineName: nil, openChannel: { channel }, evaluate: { scripts.append($0) })
        _ = await bridge.handle(["method": "transport.open"])
        channel.end()
        for _ in 0..<200 where scripts.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(scripts.first?.contains(#""closed""#) == true)
        #expect(bridge.openConnections == 0)
    }

    @Test func nativeOnlyMethodsAreRefusedAsUnsupported() async {
        let bridge = AgentPaneWebBridge(sessionID: nil, machineName: nil, openChannel: { EchoAcpmuxChannel() }, evaluate: { _ in })
        let reply = await bridge.handle(["method": "dictation.start"])
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "native.unsupported")
    }
}

/// Answers every request with an empty result, as acpmux answers `initialize`.
private final class EchoAcpmuxChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 7
    private let lock = NSLock()
    private var queue: [Data] = []
    private var ended = false
    private var waiter: CheckedContinuation<Data?, Never>?
    private var frames: [String] = []

    var sent: [String] { lock.withLock { frames } }

    func send(_ data: Data) async throws {
        let text = String(decoding: data, as: UTF8.self)
        guard let request = try? JSONDecoder().decode(JSONValue.self, from: data), let id = request["id"]?.numberValue else {
            lock.withLock { frames.append(text) }
            return
        }
        deliver(Data(#"{"jsonrpc":"2.0","id":\#(Int(id)),"result":{}}"#.utf8), sent: text)
    }

    private func deliver(_ reply: Data, sent: String) {
        let waiting: CheckedContinuation<Data?, Never>? = lock.withLock {
            frames.append(sent)
            if let waiter { self.waiter = nil; return waiter }
            queue.append(reply)
            return nil
        }
        waiting?.resume(returning: reply)
    }

    func end() {
        let waiting: CheckedContinuation<Data?, Never>? = lock.withLock {
            ended = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: nil)
    }

    func receive() async throws -> Data? {
        await withCheckedContinuation { continuation in
            let ready: Data?? = lock.withLock {
                if !queue.isEmpty { return .some(queue.removeFirst()) }
                if ended { return .some(nil) }
                waiter = continuation
                return .none
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func close(code: String, reason: String) async { end() }
}
