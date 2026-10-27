import Foundation
import Testing
import CmuxNextPagesTestSupport
@testable import CmuxNextAgentPane

@Suite(.serialized) @MainActor
struct AcpmuxUploadOwnershipTests {
    private let owner = "0123456789abcdef0123456789abcdef"
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
    private func frames(_ wire: AcpmuxUploadFrameTests.UploadWire) throws -> [[String: Any]] {
        try wire.sentFrames.withLock { $0 }.map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    private func socket(_ wire: AcpmuxUploadFrameTests.UploadWire) async throws -> AcpmuxPaneSocket {
        let transport = AgentPaneTransport()
        let socket = AcpmuxPaneSocket(request: URLRequest(url: URL(string: "ws://127.0.0.1")!), wire: wire,
            limits: transport.limits, options: transport.permissionOptions, sessions: transport.sessions,
            ids: AcpmuxRequestIds(), signal: {})
        try await socket.start(timeout: 1)
        return socket
    }
    @Test func ownershipIsNativeAndBoundToTheBeginSession() async throws {
        let wire = AcpmuxUploadFrameTests.UploadWire(), socket = try await self.socket(wire)
        let began = try await socket.callHost("_acpmux/file_put_begin",
            params: ["sessionId": "s", "fileName": "x", "size": 0, "forPrompt": true])
        #expect(began["ownerToken"] == nil)
        #expect(!(await socket.cancelUploadAndWait(sessionId: "other", uploadId: "u")))
        #expect(wire.sentCount.withLock { $0 } == 1, "another session reached cancellation")
        #expect(await socket.cancelUploadAndWait(sessionId: "s", uploadId: "u"))
        let cancel = try #require(try frames(wire).last?["params"] as? [String: Any])
        #expect(cancel["ownerToken"] as? String == owner)
        socket.close(code: 1000, reason: "", error: nil)
    }
    @Test func missingOrMalformedOwnershipCannotAuthorizeCleanup() async throws {
        for token in [nil, "short", "0123456789ABCDEF0123456789ABCDEF"] as [String?] {
            let wire = AcpmuxUploadFrameTests.UploadWire(ownerToken: token), socket = try await self.socket(wire)
            await #expect(throws: AgentPaneUploadError.self) {
                try await socket.callHost("_acpmux/file_put_begin",
                    params: ["sessionId": "s", "fileName": "x", "size": 0, "forPrompt": true])
            }
            #expect(!(await socket.cancelUploadAndWait(sessionId: "s", uploadId: "u")))
            #expect(wire.sentCount.withLock { $0 } == 1)
            socket.close(code: 1000, reason: "", error: nil)
        }
    }
    @Test func lateBeginCleanupCarriesNativeOwnership() async throws {
        let sent = AsyncStream<Void>.makeStream()
        let wire = AcpmuxUploadFrameTests.UploadWire(holdBegin: true, onSend: { sent.continuation.yield() })
        let socket = try await self.socket(wire)
        let task = Task { _ = try await socket.callHost("_acpmux/file_put_begin",
            params: ["sessionId": "s", "fileName": "x", "size": 0, "forPrompt": true]) }
        var sends = sent.stream.makeAsyncIterator()
        _ = await sends.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        wire.reply(begin: true)
        _ = await sends.next()
        let cancel = try #require(try frames(wire).last?["params"] as? [String: Any])
        #expect(cancel["ownerToken"] as? String == owner)
        #expect(cancel["sessionId"] as? String == "s")
        #expect(socket.queuedFrames == 0, "the ownership reply reached the page")
        sent.continuation.finish()
        socket.close(code: 1000, reason: "", error: nil)
    }
    @Test(arguments: [true, false]) func terminalCleanupKeepsOneStateAndNoPageSecret(_ finished: Bool) async throws {
        let wire = AcpmuxUploadFrameTests.UploadWire(), transport = AgentPaneTransport()
        let model = AgentPaneModel(host: NoHost(), sessionId: "s", transport: transport)
        transport.socket = try await socket(wire); transport.current = 1; transport.uploadOriginAllowed = true
        let handler = try #require(AgentPaneView.chromiumUploadHandler(for: model))
        let coordinator = try #require(model.nativeUploadCoordinator)
        var events = [AgentPageEvent](); coordinator.publish = { events.append($0); return true }
        transport.gestures.record()
        let intent = try #require(AgentPaneGestureIntent(gestureParams: ["intent": [
            "method": "session/prompt", "params": ["promptId": "p", "sessionId": "s"]]]))
        let ticket = try #require(transport.reserveGesture(intent))
        let params: [String: Any] = ["token": "t", "name": "x", "type": "text/plain", "size": finished ? 0 : 1,
                                     "sessionId": "s", "promptId": "p", "ticket": ticket]
        let chunks = AsyncThrowingStream<Data, any Error> {
            if !finished { $0.yield(Data([1])) }
            $0.finish()
        }
        let reply = try #require(await handler(FakeChromiumPage(), 9, params, chunks))
        #expect(reply["ok"] as? Bool == finished)
        let begin = try #require(try frames(wire).first?["params"] as? [String: Any])
        #expect(begin["forPrompt"] as? Bool == true)
        #expect(try frames(wire).count == (finished ? 2 : 3), "successful refs must survive; failed attempts must be cleaned")
        if !finished {
            let cleanup = try #require(try frames(wire).last?["params"] as? [String: Any])
            #expect(cleanup["ownerToken"] as? String == owner)
        }
        let status = try #require(await coordinator.query("cmux.agent.uploads.cancel", context: 9, params: ["token": "t"]))
        #expect((status["value"] as? [String: Any])?["state"] as? String == (finished ? "finished" : "failed"))
        #expect(events.count == 1)
        #expect(!String(describing: reply).contains(owner) && !String(describing: status).contains(owner))
        #expect(!String(describing: events).contains(owner))
        let cancel = try #require(try frames(wire).last?["params"] as? [String: Any])
        #expect(cancel["ownerToken"] as? String == owner)
        transport.socket?.close(code: 1000, reason: "", error: nil)
    }
}
