@testable import CmuxNextMacScreen
import CmuxScreenKit
import Darwin
import Foundation
import Testing

/// Every Mac Screen session this Mac serves is captured by cmux Computer Use's Screen Sharing
/// worker: the app opens one worker channel per session and relays its signaling, and never
/// captures itself. The worker here is the far end of a socket pair.
@Suite(.timeLimit(.minutes(1)))
struct MacScreenCaptureWorkerTests {
    /// The worker's end of the session channel: blocking line reads off the test's task.
    nonisolated final class FakeWorker: Sendable {
        let socket: Int32
        let app: Int32

        init() throws {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
            socket = pair[0]
            app = pair[1]
        }

        var worker: MacScreenCaptureWorker {
            let app = app
            return MacScreenCaptureWorker(channel: { app })
        }

        func read() async -> [String: Any]? {
            let socket = socket
            let line = await Task.detached { RemoteSocket.readLine(socket) }.value
            return line.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }

        func write(_ object: [String: Any]) {
            guard var line = try? JSONSerialization.data(withJSONObject: object) else { return }
            line.append(0x0A)
            _ = RemoteSocket.writeAll(socket, line)
        }
    }

    private let session = MacScreenRdHost.Session(id: "s1", name: "Studio", viewerID: "v1", viewerName: "iPhone", viewOnly: true,
                                                  servers: MacScreenRdServers([]))

    @Test func aWebRTCViewerIsServedByTheWorkerWithItsSignalingRelayed() async throws {
        let fake = try FakeWorker()
        let host = MacScreenRdHost(session: session, worker: fake.worker)
        let (events, sink) = AsyncStream.makeStream(of: MacScreenRdHost.Event.self)
        host.onEvent = { sink.yield($0) }
        let offer = ScreenSignal.offer("v=0\r\na=fingerprint:sha-256 AB:CD\r\n")
        let signaling = MacScreenRdHostRoutingTests.FedSignaling([offer])
        let serving = Task { try await host.serve(signaling) }

        let request = try #require(await fake.read())
        #expect(request["method"] as? String == "session.webrtc")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["session_id"] as? String == "s1")
        #expect(params["scope"] as? String == "view")
        #expect(params["viewer_name"] as? String == "iPhone")
        fake.write(["id": 1, "ok": true, "result": ["pid": 1]])

        let relayed = try #require(await fake.read())
        #expect(ScreenSignalWire.signal(try #require(relayed["signal"] as? [String: Any])) == offer)
        #expect(await fake.read()?["signals_done"] as? Bool == true)
        try await serving.value

        fake.write(["signal": ScreenSignalWire.fields(.answer("v=0 answer"))])
        fake.write(["type": "event", "event": "session", "kind": "connected"])
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .viewerConnected)
        #expect(signaling.sent.contains(.answer("v=0 answer")))

        host.disconnectViewer()
        #expect(await fake.read()?["stop"] as? Bool == true)
    }

    @Test func aCmuxRdViewerStartsTheHostInTheWorker() async throws {
        let fake = try FakeWorker()
        let host = MacScreenRdHost(session: session, worker: fake.worker)
        var document = MacScreenRdDocument(key: String(repeating: "ab", count: 32))
        document.candidates = ["host 192.168.1.4:51000"]
        let serving = Task { try await host.serve(MacScreenRdHostRoutingTests.FedSignaling([.offer(document.text)])) }

        let request = try #require(await fake.read())
        #expect(request["method"] as? String == "session.rd")
        fake.write(["id": 1, "ok": true, "result": ["pid": 42]])
        let setup = try #require(await fake.read())
        #expect(setup["peer_key"] as? String == document.key)
        #expect(setup["scope"] as? String == "view")
        #expect(await fake.read()?["candidate"] as? String == "host 192.168.1.4:51000")
        try await serving.value
        #expect(host.startedProcess)
    }

    @Test func aRefusedChannelFailsTheSession() async throws {
        let fake = try FakeWorker()
        let host = MacScreenRdHost(session: session, worker: fake.worker)
        let (events, sink) = AsyncStream.makeStream(of: MacScreenRdHost.Event.self)
        host.onEvent = { sink.yield($0) }
        let document = MacScreenRdDocument(key: String(repeating: "cd", count: 32))
        let serving = Task { try await host.serve(MacScreenRdHostRoutingTests.FedSignaling([.offer(document.text)])) }
        _ = await fake.read()
        fake.write(["id": 1, "ok": false, "error": ["code": "rd_unavailable", "message": "no cmux.rd/1 host"]])
        try await serving.value
        var iterator = events.makeAsyncIterator()
        guard case let .sourceFailed(message) = await iterator.next() else { Issue.record("no failure"); return }
        #expect(message.contains("no cmux.rd/1 host"))
    }

    /// No worker (cmux Computer Use not running): the session fails; nothing serves in the app.
    @Test func withoutTheWorkerNothingServes() async throws {
        let host = MacScreenRdHost(session: session)
        let (events, sink) = AsyncStream.makeStream(of: MacScreenRdHost.Event.self)
        host.onEvent = { sink.yield($0) }
        try await host.serve(MacScreenRdHostRoutingTests.FedSignaling([.offer("v=0\r\n")]))
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .sourceFailed(MacScreenCaptureWorker.unavailable))
    }
}
