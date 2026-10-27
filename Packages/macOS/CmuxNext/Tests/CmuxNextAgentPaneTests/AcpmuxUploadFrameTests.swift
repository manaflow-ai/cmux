import Foundation
import CmuxNextCompat
import CmuxNextWakeups
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxUploadFrameTests {
    @MainActor final class Completion {
        var waiting: CheckedContinuation<Bool, Never>?
        func finish(_ value: Bool) { waiting?.resume(returning: value); waiting = nil }
    }
    @Test func uploadControlDoesNotAllowDataBytesInPageParams() {
        let body: [String: Any] = [
            "method": "_acpmux/file_put_begin",
            "params": ["sessionId": "s", "fileName": "x", "size": 42],
        ]
        #expect(AcpmuxPaneMethods.breaksParamsRule(body, modeFields: nil) == false)
        #expect(AcpmuxPaneMethods.breaksParamsRule([
            "method": "_acpmux/file_put_begin",
            "params": ["sessionId": "s", "fileName": "x", "size": 42, "data": "AA=="],
        ], modeFields: nil))
    }

    @Test func sanctionedUploadRefsKeepOnlyTheirExactMetadata() throws {
        for (kind, uri): (String, String?) in [("image", nil), ("resource_link", "acpmux-upload:u")] {
            var block: [String: Any] = ["type": kind, "name": "data.bin",
                "_meta": ["acpmux": ["upload": ["uploadId": "u", "fileName": "data.bin"], "ignored": true], "ignored": true]]
            if let uri { block["uri"] = uri }
            let frame: [String: Any] = ["method": "session/prompt", "params": ["prompt": [block]]]
            let result = try #require(AcpmuxPaneMethods.strippingPromptMeta(frame))
            let blocks = try #require((result["params"] as? [String: Any])?["prompt"] as? [[String: Any]])
            let kept = try #require(blocks.first)
            let meta = try #require(kept["_meta"] as? [String: Any])
            let acpmux = try #require(meta["acpmux"] as? [String: Any])
            let upload = try #require(acpmux["upload"] as? [String: Any])
            #expect(upload["uploadId"] as? String == "u" && upload["fileName"] as? String == "data.bin")
            #expect(meta.count == 1 && acpmux.count == 1 && upload.count == 2)
            #expect(kept["uri"] as? String == uri)
        }
    }
    @Test func invalidOrNestedUploadMetadataDoesNotSurvive() throws {
        for block: [String: Any] in [
            ["type": "image", "data": "AA==", "_meta": ["acpmux": ["upload": ["uploadId": "u", "fileName": "x"]]]],
            ["type": "resource_link", "uri": "acpmux-upload:other", "_meta": ["acpmux": ["upload": ["uploadId": "u", "fileName": "x"]]]],
            ["type": "text", "annotations": ["type": "image", "_meta": ["acpmux": ["upload": ["uploadId": "u", "fileName": "x"]]]]],
        ] {
            let frame: [String: Any] = ["method": "session/prompt", "params": ["prompt": [block]]]
            let result = try #require(AcpmuxPaneMethods.strippingPromptMeta(frame))
            let data = try JSONSerialization.data(withJSONObject: result)
            #expect(!String(decoding: data, as: UTF8.self).contains("uploadId"))
        }
    }

    @Test @MainActor func socketCloseAnswersPendingHostUpload() async throws {
        let transport = AgentPaneTransport()
        let socket = AcpmuxPaneSocket(
            request: URLRequest(url: URL(string: "ws://127.0.0.1")!),
            wire: UploadWire(closeOnSend: true), limits: transport.limits,
            options: transport.permissionOptions, sessions: transport.sessions,
            ids: AcpmuxRequestIds(), signal: {})
        try await socket.start(timeout: 1)
        await #expect(throws: AgentPaneUploadError.rpc("upload connection closed")) {
            try await socket.callHost("_acpmux/file_put_begin", params: ["sessionId": "s", "fileName": "x", "size": 1])
        }
    }

    @Test @MainActor func cancellationEndsPendingUploadBeforeLateAcknowledgement() async throws {
        let sent = AsyncStream<Void>.makeStream()
        let wire = UploadWire(holdReply: true, holdBegin: true, onSend: { sent.continuation.yield() })
        let transport = AgentPaneTransport()
        let socket = AcpmuxPaneSocket(request: URLRequest(url: URL(string: "ws://127.0.0.1")!),
            wire: wire, limits: transport.limits, options: transport.permissionOptions,
            sessions: transport.sessions, ids: AcpmuxRequestIds(), signal: {})
        try await socket.start(timeout: 1)
        let request = Task { _ = try await socket.callHost("_acpmux/file_put_begin", params: ["sessionId": "s"]); return true }
        var events = sent.stream.makeAsyncIterator()
        _ = await events.next()
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        let completion = Completion(), deadline = DemandTimer(owner: "test.upload.late-begin")
        let cleaned = await withCheckedContinuation { continuation in
            completion.waiting = continuation
            deadline.schedule(after: .seconds(2)) { completion.finish(false) }
            Task { completion.finish(await events.next() != nil) }
            wire.reply(begin: true)
        }
        deadline.cancel()
        sent.continuation.finish()
        #expect(cleaned && wire.sentCount.withLock { $0 } == 2, "late begin ACK did not cancel its partial upload")
        socket.close(code: 1000, reason: "", error: nil)
    }

    @Test @MainActor func uploadsRequireNativeOriginAndPaneSessionScope() async throws {
        let wire = UploadWire()
        let transport = AgentPaneTransport()
        let socket = AcpmuxPaneSocket(
            request: URLRequest(url: URL(string: "ws://127.0.0.1")!),
            wire: wire, limits: transport.limits, options: transport.permissionOptions,
            sessions: transport.sessions, ids: AcpmuxRequestIds(), signal: {})
        try await socket.start(timeout: 1)
        transport.socket = socket
        transport.current = 1
        transport.uploadOriginAllowed = true
        await #expect(throws: AgentPaneUploadError.rpc("upload session outside pane scope")) {
            try await transport.uploadControl(connection: 1, method: "_acpmux/file_put_begin", params: ["sessionId": "foreign"])
        }
        await #expect(throws: AgentPaneUploadError.rpc("upload session outside pane scope")) {
            try await transport.uploadChunk(connection: 1, sessionId: "foreign", uploadId: "u", offset: 0, bytes: Data([1]))
        }
        #expect(wire.sentCount.withLock { $0 } == 0)
        transport.sessions.add("owned")
        transport.uploadOriginAllowed = false
        await #expect(throws: AgentPaneUploadError.rpc("uploads require a native app connection")) {
            try await transport.uploadControl(connection: 1, method: "_acpmux/file_put_cancel", params: ["sessionId": "owned"])
        }
        #expect(wire.sentCount.withLock { $0 } == 0)
        socket.close(code: 1000, reason: "", error: nil)
    }

    final class UploadWire: AcpmuxPaneWire, Sendable {
        let sentCount = Mutex(0)
        private let lastID = Mutex(0)
        private let holdReply: Bool
        private let holdBegin: Bool
        private let closeOnSend: Bool
        private let closed = Mutex<(@Sendable (Int, String) -> Void)?>(nil)
        private let onSend: @Sendable () -> Void
        init(holdReply: Bool = false, holdBegin: Bool = false, closeOnSend: Bool = false, onSend: @escaping @Sendable () -> Void = {}) {
            self.holdReply = holdReply
            self.holdBegin = holdBegin
            self.closeOnSend = closeOnSend
            self.onSend = onSend
        }
        private let incoming = Mutex<(@Sendable (String) -> Void)?>(nil)
        func open(onFrame: @escaping @Sendable (String) -> Void,
                  onClose: @escaping @Sendable (Int, String) -> Void) async throws {
            incoming.withLock { $0 = onFrame }
            closed.withLock { $0 = onClose }
        }
        func send(_ text: String, completion: @escaping @Sendable (Bool) -> Void) {
            sentCount.withLock { $0 += 1 }
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            lastID.withLock { $0 = object?["id"] as? Int ?? 0 }
            completion(true)
            onSend()
            if closeOnSend { closed.withLock { $0 }?(1006, ""); return }
            if object?["method"] as? String == "_acpmux/file_put_begin" {
                if !holdBegin { reply(begin: true) }
            } else if !holdReply || object?["method"] as? String == "_acpmux/file_put_cancel" { reply() }
        }
        func reply(begin: Bool = false) {
            let id = lastID.withLock { $0 }
            let result = begin ? #"{"uploadId":"u","offset":0}"# : #"{"offset":2}"#
            incoming.withLock { $0 }?(#"{"id":\#(id),"result":\#(result)}"#)
        }
        func cancel(code: Int, reason: String) {}
    }

}
