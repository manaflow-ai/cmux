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

    /// Reads until the peer closes: returns everything received and whether
    /// EOF was actually observed. The poll returns the instant the responder
    /// closes; the bound only stops a broken responder from hanging the
    /// suite and is generous because libdispatch runs the responder's
    /// source-cancellation handlers on a utility queue that a loaded runner
    /// can starve for seconds.
    func readUntilEOF(timeout: TimeInterval = 30) -> (text: String, sawEOF: Bool) {
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
            if count == 0 {
                return (String(decoding: collected, as: UTF8.self), true)
            }
            // A read error (ECONNRESET, EIO) is an abrupt disconnect, not
            // the clean close the responder promises.
            if count < 0, errno != EAGAIN, errno != EINTR {
                return (String(decoding: collected, as: UTF8.self), false)
            }
        }
        return (String(decoding: collected, as: UTF8.self), false)
    }

    deinit {
        if clientEnd >= 0 {
            close(clientEnd)
            clientEnd = -1
        }
    }
}

/// Records every rejection the responder reports and lets a test await the
/// next one: the callback itself is the completion signal, so no test polls.
private final class RejectionRecorder: Sendable {
    private let rejections = OSAllocatedUnfairLock(initialState: [ControlOverloadRejection]())
    private let stream: AsyncStream<ControlOverloadRejection>
    private let continuation: AsyncStream<ControlOverloadRejection>.Continuation

    init() {
        (stream, continuation) = AsyncStream<ControlOverloadRejection>.makeStream(
            bufferingPolicy: .unbounded
        )
    }

    func record(_ rejection: ControlOverloadRejection) {
        rejections.withLock { $0.append(rejection) }
        continuation.yield(rejection)
    }

    var all: [ControlOverloadRejection] {
        rejections.withLock { $0 }
    }

    /// Suspends until the responder reports the next rejection.
    func nextRejection() async -> ControlOverloadRejection? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}

@Suite("ControlOverloadResponder", .timeLimit(.minutes(1)))
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

    @Test func answersAV2RequestWithAStructuredOverloadedErrorEchoingItsID() async throws {
        let client = try RejectedClient()
        let recorder = RejectionRecorder()
        let responder = makeResponder(recorder: recorder)

        // The client writes first, exactly like `cmux` does after connect.
        client.send(#"{"id":"req-7","method":"system.ping","params":{}}"# + "\n")
        responder.reject(socket: client.serverEnd, reason: .poolSaturated)

        let reply = client.readUntilEOF()
        #expect(reply.sawEOF)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any]
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

        #expect(await recorder.nextRejection() == ControlOverloadRejection(
            reason: .poolSaturated, replied: true, activeReplies: 0
        ))
        #expect(responder.metrics().repliedConnections == 1)
    }

    @Test func answersAV1CommandWithTheLegacyErrorLine() async throws {
        let client = try RejectedClient()
        let recorder = RejectionRecorder()
        let responder = makeResponder(recorder: recorder)

        client.send("ping\n")
        responder.reject(socket: client.serverEnd, reason: .pendingExpired)

        let reply = client.readUntilEOF()
        #expect(reply.sawEOF)
        #expect(reply.text == "ERROR: overloaded retry_after_ms=250 reason=pending_expired\n")
        #expect(await recorder.nextRejection()?.replied == true)
    }

    @Test func closesASilentClientAfterTheReadDeadlineWithoutReplying() async throws {
        let client = try RejectedClient()
        let recorder = RejectionRecorder()
        let responder = makeResponder(recorder: recorder, readDeadlineMilliseconds: 100)

        responder.reject(socket: client.serverEnd, reason: .poolSaturated)

        // The read deadline is the responder's own bounded wait for the
        // client's first line; the test only waits on the resulting close.
        let reply = client.readUntilEOF()
        #expect(reply.sawEOF)
        #expect(reply.text.isEmpty)
        #expect(await recorder.nextRejection() == ControlOverloadRejection(
            reason: .poolSaturated, replied: false, activeReplies: 0
        ))
        #expect(responder.metrics().closedWithoutReply == 1)
    }

    @Test func closesImmediatelyWhenTheReplyBoundIsExhausted() async throws {
        let recorder = RejectionRecorder()
        let responder = makeResponder(recorder: recorder, maximumConcurrentReplies: 0)
        let client = try RejectedClient()

        responder.reject(socket: client.serverEnd, reason: .preauthorizationSaturated)

        let reply = client.readUntilEOF()
        #expect(reply.sawEOF)
        #expect(reply.text.isEmpty)
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
