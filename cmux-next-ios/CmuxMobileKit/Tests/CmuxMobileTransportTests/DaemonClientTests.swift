import Foundation
import Testing
@testable import CmuxMobileTransport

@Suite struct DaemonClientTests {
    @Test func orderedRepliesKeepEventPositionsAndMissingRepliesExpire() async throws {
        let link = MockMacLink { _, bytes in
            var result = [Data]()
            for line in bytes.split(separator: 0x0A) {
                let object = try! JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
                guard object["cmd"] as? String != "drop" else { continue }
                result.append(Data("{\"event\":\"tree.changed\"}\n".utf8))
                result.append(Data("{\"id\":\"\(object["id"]!)\",\"ok\":true}\n".utf8))
            }
            return result
        }
        let client = DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]), orderedEvents: true)
        let replies = await client.requestsOrdered([("drop", [:]), ("ping", [:])], deadline: .milliseconds(20))
        if case .failure(let error) = replies[0] {
            #expect((error as? LinkError)?.code == DaemonClient.replyTimeout)
        } else { Issue.record("Missing ordered reply succeeded") }
        let reply = try replies[1].get()
        var events = client.orderedEvents.makeAsyncIterator()
        let event = await events.next()
        #expect(event?.sequence == 1)
        #expect(reply.sequence == 2)
        #expect(await client.receivedPosition == 2)
        var unused = client.events.makeAsyncIterator()
        #expect(await unused.next() == nil)
        await client.close()
    }

    @Test func unsolicitedEventsApplyByteBackpressureWithoutDroppingOrder() async throws {
        let buffer = BoundedDaemonEventBuffer(capacity: 4)
        #expect(await buffer.push(Data("one".utf8)))
        let blocked = Task { await buffer.push(Data("two".utf8)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!blocked.isCancelled)
        #expect(await buffer.pendingBytes == 3)
        var iterator = DaemonEventStream(buffer: buffer).makeAsyncIterator()
        #expect(await iterator.next() == Data("one".utf8))
        #expect(await blocked.value)
        #expect(await iterator.next() == Data("two".utf8))
        await buffer.finish()
        #expect(await iterator.next() == nil)
    }

    @Test func repliesRouteByIDAndEventsStream() async throws {
        let link = MockMacLink { _, request in
            let object = try! JSONSerialization.jsonObject(with: request.dropLast()) as! [String: Any]
            let id = object["id"] as! String
            let event = Data(#"{"event":"tree.changed"}"#.utf8) + Data([0x0A])
            // Reply split across two chunks to exercise line buffering.
            let reply = Data(#"{"id":"\#(id)","ok":true,"data":{"cmd":"\#(object["cmd"]!)"}}"#.utf8) + Data([0x0A])
            return [event, reply.prefix(10), reply.dropFirst(10)]
        }
        let channel = try await link.openChannel(service: "daemon", args: [:])
        let client = DaemonClient(channel: channel)
        let reply = try await client.request("identify")
        let object = try JSONSerialization.jsonObject(with: reply) as! [String: Any]
        #expect(object["ok"] as? Bool == true)
        var iterator = client.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event.map { String(decoding: $0, as: UTF8.self) } == #"{"event":"tree.changed"}"#)
    }

    /// The connect setup goes out as one write and the replies come back in order.
    @Test func batchSendsOneWriteAndKeepsOrder() async throws {
        let writes = Counter()
        let link = MockMacLink { _, request in
            writes.add()
            var replies = Data()
            for line in request.split(separator: 0x0A) {
                let object = try! JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
                let id = object["id"] as! String
                let ok = object["cmd"] as! String != "refused"
                replies += Data(#"{"id":"\#(id)","ok":\#(ok),"data":{"cmd":"\#(object["cmd"]!)"}}"#.utf8) + Data([0x0A])
            }
            // Replies in one chunk, as a fast Mac sends them.
            return [replies]
        }
        let channel = try await link.openChannel(service: "daemon", args: [:])
        let client = DaemonClient(channel: channel)
        let results = await client.requests([("identify", [:]), ("refused", [:]), ("list-workspaces", [:])])
        #expect(writes.value == 1)
        let commands = results.map { result -> String? in
            guard let data = try? result.get(),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (object["data"] as? [String: Any])?["cmd"] as? String
        }
        #expect(commands == ["identify", "refused", "list-workspaces"])
    }

    @Test func missingNormalAndResourceRepliesFailAndLaterRequestsWork() async throws {
        let link = MockMacLink { _, bytes in
            let object = try! JSONSerialization.jsonObject(with: bytes.dropLast()) as! [String: Any]
            guard object["cmd"] as? String == "ping" else { return [] }
            return [Data("{\"id\":\"\(object["id"]!)\",\"ok\":true}\n".utf8)]
        }
        let client = DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        await #expect(throws: LinkError(code: DaemonClient.replyTimeout, message: "reply timed out")) {
            try await client.request("list-workspaces", deadline: .milliseconds(20))
        }
        await #expect(throws: LinkError(code: DaemonClient.replyTimeout, message: "reply timed out")) {
            try await client.resourceRequest("workspace.list", deadline: .milliseconds(20))
        }
        let reply = try await client.request("ping")
        #expect(String(decoding: reply, as: UTF8.self).contains("true"))
        await client.close()
    }

    @Test func oneMissingBatchReplyDoesNotLoseOtherReplies() async throws {
        let link = MockMacLink { _, bytes in
            bytes.split(separator: 0x0A).compactMap { line in
                let object = try! JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
                guard object["cmd"] as? String != "drop" else { return nil }
                return Data("{\"id\":\"\(object["id"]!)\",\"ok\":true}\n".utf8)
            }
        }
        let client = DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        let replies = await client.requests([("drop", [:]), ("ping", [:])], deadline: .milliseconds(20))
        if case .failure(let error) = replies[0] {
            #expect((error as? LinkError)?.code == DaemonClient.replyTimeout)
        } else { Issue.record("Missing reply succeeded") }
        #expect(try replies[1].get().isEmpty == false)
        await client.close()
    }

    @Test func submittedReplyCanExpireBeforeItIsAwaited() async throws {
        let link = MockMacLink { _, _ in [] }
        let client = DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        let id = try await client.submit("send", deadline: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: LinkError(code: DaemonClient.replyTimeout, message: "reply timed out")) {
            try await client.reply(to: id)
        }
        await client.close()
    }

    @Test func cancellingReplyDoesNotWaitForDeadline() async throws {
        let link = MockMacLink { _, _ in [] }
        let client = DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        let id = try await client.submit("send", deadline: .seconds(60))
        let waiter = Task { try await client.reply(to: id) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await client.close()
    }

    @Test func lateReplyIsDroppedInsteadOfBecomingAnEvent() async throws {
        let channel = DeadlineTestChannel()
        let client = DaemonClient(channel: channel)
        let id = try await client.submit("send", deadline: .milliseconds(20))
        await #expect(throws: LinkError.self) { try await client.reply(to: id) }
        channel.deliver(Data("{\"id\":\"\(id)\",\"ok\":true}\n{\"event\":\"tree.changed\"}\n".utf8))
        var iterator = client.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event.map { String(decoding: $0, as: UTF8.self) } == "{\"event\":\"tree.changed\"}")
        await client.close()
    }

    @Test(.timeLimit(.minutes(1))) func anEarlyReplySurvivesEOFBeforeReplyIsAwaited() async throws {
        let channel = ReplyThenEOFChannel()
        let client = DaemonClient(channel: channel)
        let id = try await client.submit("send")
        // Stream completion happens after finish has set the channel error;
        // do not race reply(to:) against the reader with a scheduling sleep.
        var events = client.events.makeAsyncIterator()
        #expect(await events.next() == nil)
        let reply = try await client.reply(to: id)
        #expect(String(decoding: reply, as: UTF8.self).contains("\"ok\":true"))
    }

    /// Leo, 2026-11-24: "a 10s timeout that kills messages while they're making progress is a
    /// shame. make it progress-based, not a wall clock". A write the link keeps taking runs
    /// past twice its deadline and is answered; the fixed cut would have dropped it, and the count
    /// says so. Its 50 ms steps sit far inside the 400 ms stall window, so a loaded runner still
    /// sees movement in every window.
    @Test(.timeLimit(.minutes(1))) func aSlowSendThatKeepsMovingOutlivesItsDeadline() async throws {
        let channel = SlowWriteChannel(steps: 20, pause: .milliseconds(50), moves: true)
        let client = DaemonClient(channel: channel)
        let started = ContinuousClock.now
        let id = try await client.submit("send", deadline: .milliseconds(400))
        let reply = try await client.reply(to: id)
        #expect(ContinuousClock.now - started >= .milliseconds(1000))
        #expect(String(decoding: reply, as: UTF8.self).contains("\"ok\":true"))
        #expect(await client.outlivedFixedDeadline == 1)
        await client.close()
    }

    /// A write the link stopped taking is still cut once it made no progress for its deadline.
    @Test(.timeLimit(.minutes(1))) func aStalledSendIsCutAtItsDeadline() async throws {
        let channel = SlowWriteChannel(steps: 80, pause: .milliseconds(50), moves: false)
        let client = DaemonClient(channel: channel)
        let started = ContinuousClock.now
        await #expect(throws: LinkError(code: "write_timeout", message: "write timed out")) {
            _ = try await client.submit("send", deadline: .milliseconds(400))
        }
        #expect(ContinuousClock.now - started < .milliseconds(3000))
        #expect(await client.outlivedFixedDeadline == 0)
        await client.close()
    }

    /// An answer to an earlier send is progress for the ones written after it (the daemon
    /// answers a connection's lines in order): a queue of slow answers is not cut one by one.
    @Test(.timeLimit(.minutes(1))) func anEarlierAnswerIsProgressForLaterSends() async throws {
        let channel = DeadlineTestChannel()
        let client = DaemonClient(channel: channel)
        let first = try await client.submit("send", deadline: .milliseconds(300))
        let second = try await client.submit("send", deadline: .milliseconds(300))
        try await Task.sleep(for: .milliseconds(200))
        channel.deliver(Data("{\"id\":\"\(first)\",\"ok\":true}\n".utf8))
        _ = try await client.reply(to: first)
        try await Task.sleep(for: .milliseconds(200))
        channel.deliver(Data("{\"id\":\"\(second)\",\"ok\":true}\n".utf8))
        _ = try await client.reply(to: second)
        #expect(await client.outlivedFixedDeadline == 1)
        await client.close()
    }

    /// Chief consumes events and sends attachment/refill requests on the same
    /// channel. Its default event stream must not block the reader before a
    /// reply that follows a large event burst.
    @Test func aGenericEventBurstDoesNotBlockAReply() async throws {
        let channel = LargeEventReplyChannel()
        let client = DaemonClient(channel: channel)
        let reply = try await client.request("snapshot", deadline: .seconds(2))
        #expect(String(decoding: reply, as: UTF8.self).contains("\"ok\":true"))
        await client.close()
    }

}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class DeadlineTestChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator
    init() {
        (stream, continuation) = AsyncStream.makeStream()
        iterator = stream.makeAsyncIterator()
    }
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data? { await iterator.next() }
    func deliver(_ data: Data) { continuation.yield(data) }
    func close(code: String, reason: String) async { continuation.finish() }
}

private final class ReplyThenEOFChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator

    init() {
        (stream, continuation) = AsyncStream.makeStream()
        iterator = stream.makeAsyncIterator()
    }

    func send(_ data: Data) async throws {
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as! [String: Any]
        let id = object["id"] as! String
        continuation.yield(Data(#"{"id":"\#(id)","ok":true}"#.utf8) + Data([0x0A]))
        continuation.finish()
    }

    func receive() async throws -> Data? { await iterator.next() }
    func close(code: String, reason: String) async { continuation.finish() }
}

private final class LargeEventReplyChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator

    init() {
        (stream, continuation) = AsyncStream.makeStream()
        iterator = stream.makeAsyncIterator()
    }

    func send(_ data: Data) async throws {
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as! [String: Any]
        let id = object["id"] as! String
        let payload = String(repeating: "x", count: 1 << 20)
        for _ in 0..<5 {
            continuation.yield(Data(#"{"event":"output","text":"\#(payload)"}"#.utf8) + Data([0x0A]))
        }
        continuation.yield(Data(#"{"id":"\#(id)","ok":true}"#.utf8) + Data([0x0A]))
    }

    func receive() async throws -> Data? { await iterator.next() }
    func close(code: String, reason: String) async { continuation.finish() }
}

/// A write that takes `steps` pauses; the link takes a share of it after each one when `moves`.
private final class SlowWriteChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let steps: Int
    private let pause: Duration
    private let moves: Bool
    private let lock = NSLock()
    private var sent: UInt64 = 0
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator

    init(steps: Int, pause: Duration, moves: Bool) {
        self.steps = steps
        self.pause = pause
        self.moves = moves
        (stream, continuation) = AsyncStream.makeStream()
        iterator = stream.makeAsyncIterator()
    }

    var sentBytes: UInt64? { lock.withLock { sent } }

    func send(_ data: Data) async throws {
        for _ in 0..<steps {
            try await Task.sleep(for: pause)
            if moves { lock.withLock { sent += UInt64(data.count / steps + 1) } }
        }
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as! [String: Any]
        continuation.yield(Data(#"{"id":"\#(object["id"] as! String)","ok":true}"#.utf8) + Data([0x0A]))
    }

    func receive() async throws -> Data? { await iterator.next() }
    func close(code: String, reason: String) async { continuation.finish() }
}
