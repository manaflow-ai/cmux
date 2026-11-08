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

    /// Waits for the responder to close its end, off the cooperative pool the
    /// responder's reply runs on; see ``UnixSocketFixture/readUntilEOF(_:timeout:)``.
    func readUntilEOF() async -> (text: String, sawEOF: Bool) {
        await UnixSocketFixture.readUntilEOF(clientEnd)
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
        // Only the silent-client test waits on the read deadline, and it sets
        // its own. Every other client writes before the responder reads, so a
        // generous default keeps a starved runner from closing without a reply.
        readDeadlineMilliseconds: Int = 30_000
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

        let reply = await client.readUntilEOF()
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

        let reply = await client.readUntilEOF()
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
        let reply = await client.readUntilEOF()
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

        let reply = await client.readUntilEOF()
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
