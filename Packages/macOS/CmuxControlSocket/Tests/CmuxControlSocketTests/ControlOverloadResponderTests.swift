@testable import CmuxControlSocket
import Darwin
import Foundation
import os
import Testing

/// One end of a `socketpair(2)` acting as the CLI client; the responder owns
/// the other end. Close-once tracking keeps parallel tests from double
/// closing a recycled descriptor number.
private final class RejectedClient {
    let serverEnd: Int32
    private var clientEnd: Int32

    init() throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        serverEnd = pair.reader
        clientEnd = pair.writer
    }

    func send(_ line: String) {
        let bytes = Array(line.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(clientEnd, buffer.baseAddress, buffer.count)
        }
    }

    /// Reads until the peer closes or `timeout` elapses; a bounded poll of
    /// the real EOF condition, not a fixed sleep.
    func readUntilEOF(timeout: TimeInterval = 5) -> String {
        var collected = [UInt8]()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var descriptor = pollfd(fd: clientEnd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let remaining = max(0, Int(deadline.timeIntervalSinceNow * 1_000))
            guard poll(&descriptor, 1, Int32(min(remaining, 100))) > 0 else { continue }
            let count = buffer.withUnsafeMutableBufferPointer { raw in
                Darwin.read(clientEnd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                break
            }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    var peerClosed: Bool {
        var descriptor = pollfd(fd: clientEnd, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        if descriptor.revents & Int16(POLLHUP) != 0 { return true }
        var probe: UInt8 = 0
        return Darwin.recv(clientEnd, &probe, 1, MSG_PEEK) == 0
    }

    deinit {
        if clientEnd >= 0 {
            close(clientEnd)
            clientEnd = -1
        }
    }
}

private final class RejectionRecorder: Sendable {
    private let rejections = OSAllocatedUnfairLock(initialState: [ControlOverloadRejection]())

    func record(_ rejection: ControlOverloadRejection) {
        rejections.withLock { $0.append(rejection) }
    }

    var all: [ControlOverloadRejection] {
        rejections.withLock { $0 }
    }
}

@Suite("ControlOverloadResponder")
struct ControlOverloadResponderTests {
    private func makeResponder(
        recorder: RejectionRecorder,
        maximumConcurrentReplies: Int = 64,
        readDeadlineMilliseconds: Int = 2_000
    ) -> ControlOverloadResponder {
        ControlOverloadResponder(
            strings: ControlOverloadResponder.Strings(message: "cmux is busy"),
            configuration: ControlOverloadResponder.Configuration(
                maximumConcurrentReplies: maximumConcurrentReplies,
                readDeadlineMilliseconds: readDeadlineMilliseconds,
                retryAfterMilliseconds: 250
            ),
            onRejection: { recorder.record($0) }
        )
    }

    private func waitForRejections(_ recorder: RejectionRecorder, count: Int) async {
        for _ in 0..<50_000 where recorder.all.count < count {
            await Task.yield()
        }
    }

    @Test func answersAV2RequestWithAStructuredOverloadedErrorEchoingItsID() async throws {
        let client = try RejectedClient()
        let recorder = RejectionRecorder()
        let responder = makeResponder(recorder: recorder)

        // The client writes first, exactly like `cmux` does after connect.
        client.send(#"{"id":"req-7","method":"system.ping","params":{}}"# + "\n")
        responder.reject(socket: client.serverEnd, reason: .poolSaturated)

        let reply = client.readUntilEOF()
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        )
        #expect(object["ok"] as? Bool == false)
        #expect(object["id"] as? String == "req-7")
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "overloaded")
        #expect(error["message"] as? String == "cmux is busy")
        let data = try #require(error["data"] as? [String: Any])
        #expect(data["retryable"] as? Bool == true)
        #expect(data["retry_after_ms"] as? Int == 250)
        #expect(data["reason"] as? String == "pool_saturated")
        #expect(client.peerClosed)

        await waitForRejections(recorder, count: 1)
        #expect(recorder.all == [
            ControlOverloadRejection(reason: .poolSaturated, replied: true, activeReplies: 0),
        ])
        #expect(responder.metrics().repliedConnections == 1)
    }

    @Test func answersAV1CommandWithTheLegacyErrorLine() async throws {
        let client = try RejectedClient()
        let recorder = RejectionRecorder()
        let responder = makeResponder(recorder: recorder)

        client.send("ping\n")
        responder.reject(socket: client.serverEnd, reason: .pendingExpired)

        let reply = client.readUntilEOF()
        #expect(reply == "ERROR: overloaded retry_after_ms=250 reason=pending_expired\n")
        await waitForRejections(recorder, count: 1)
        #expect(recorder.all.first?.replied == true)
    }

    @Test func closesASilentClientAfterTheReadDeadlineWithoutReplying() async throws {
        let client = try RejectedClient()
        let recorder = RejectionRecorder()
        let responder = makeResponder(recorder: recorder, readDeadlineMilliseconds: 100)

        responder.reject(socket: client.serverEnd, reason: .poolSaturated)

        // The read deadline is the responder's own bounded wait for the
        // client's first line; the test only waits on the resulting close.
        let reply = client.readUntilEOF()
        #expect(reply.isEmpty)
        #expect(client.peerClosed)
        await waitForRejections(recorder, count: 1)
        #expect(recorder.all == [
            ControlOverloadRejection(reason: .poolSaturated, replied: false, activeReplies: 0),
        ])
        #expect(responder.metrics().closedWithoutReply == 1)
    }

    @Test func closesImmediatelyWhenTheReplyBoundIsExhausted() async throws {
        let recorder = RejectionRecorder()
        let responder = makeResponder(recorder: recorder, maximumConcurrentReplies: 0)
        let client = try RejectedClient()

        responder.reject(socket: client.serverEnd, reason: .preauthorizationSaturated)

        #expect(client.readUntilEOF().isEmpty)
        #expect(client.peerClosed)
        #expect(recorder.all == [
            ControlOverloadRejection(reason: .preauthorizationSaturated, replied: false, activeReplies: 0),
        ])
        #expect(responder.metrics().closedWithoutReply == 1)
    }

    @Test func responseShapePerLineIsDeterministic() {
        let responder = ControlOverloadResponder(
            strings: ControlOverloadResponder.Strings(message: "busy"),
            configuration: ControlOverloadResponder.Configuration(retryAfterMilliseconds: 500)
        )
        let v2 = responder.response(
            forRequestLine: #"{"id":42,"method":"workspace.list","params":{}}"#,
            reason: .serverStopping
        )
        #expect(v2.contains(#""id":42"#))
        #expect(v2.contains(#""code":"overloaded""#))
        #expect(v2.contains(#""reason":"server_stopping""#))
        #expect(
            responder.response(forRequestLine: "list_workspaces", reason: .poolSaturated)
                == "ERROR: overloaded retry_after_ms=500 reason=pool_saturated"
        )
    }
}
