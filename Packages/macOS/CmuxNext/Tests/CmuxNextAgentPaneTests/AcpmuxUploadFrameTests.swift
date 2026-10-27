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
    @Test @MainActor func daemonErrorDataPreservesUploadReasonAndPath() async throws {
        let wire = UploadWire(errorResponse: true)
        let transport = AgentPaneTransport()
        let socket = AcpmuxPaneSocket(request: URLRequest(url: URL(string: "ws://127.0.0.1")!), wire: wire,
            limits: transport.limits, options: transport.permissionOptions, sessions: transport.sessions,
            ids: AcpmuxRequestIds(), signal: {})
        try await socket.start(timeout: 1)
        await #expect(throws: AgentPaneUploadError.rpcDetails(code: "upload.diskFull", message: "full", details: ["host": "h", "path": "/v"])) {
            try await socket.callHost("_acpmux/file_put_begin", params: ["sessionId": "s"])
        }
        socket.close(code: 1000, reason: "", error: nil)
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
            deadline.schedule(after: .seconds(2)) { await completion.finish(false) }
            Task.detached {
                var cleanupEvents = sent.stream.makeAsyncIterator()
                await completion.finish(await cleanupEvents.next() != nil)
            }
            wire.reply(begin: true)
        }
        deadline.cancel()
        sent.continuation.finish()
        #expect(cleaned && wire.sentCount.withLock { $0 } == 2, "late begin ACK did not cancel its partial upload")
        socket.close(code: 1000, reason: "", error: nil)
    }

    final class UploadWire: AcpmuxPaneWire, Sendable {
        let sentCount = Mutex(0)
        private let lastID = Mutex(0)
        private let holdReply: Bool
        private let holdBegin: Bool
        private let closeOnSend: Bool
        private let errorResponse: Bool
        private let closed = Mutex<(@Sendable (Int, String) -> Void)?>(nil)
        private let onSend: @Sendable () -> Void
        init(holdReply: Bool = false, holdBegin: Bool = false, closeOnSend: Bool = false, errorResponse: Bool = false, onSend: @escaping @Sendable () -> Void = {}) {
            self.holdReply = holdReply
            self.holdBegin = holdBegin
            self.closeOnSend = closeOnSend
            self.errorResponse = errorResponse
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
            if errorResponse { let id = lastID.withLock { $0 }; incoming.withLock { $0 }?(#"{"id":\#(id),"error":{"code":-32603,"message":"full","data":{"reason":"upload.diskFull","host":"h","path":"/v"}}}"#); return }
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
