import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

@Suite(.timeLimit(.minutes(1))) struct LinkRequestDeadlineTests {
    @Test func aDroppedRPCReplyTimesOutAndTheNextRequestStillWorks() async throws {
        let channel = DeadlineChannel()
        let connection = AcpmuxConnection(channel: channel)
        do {
            _ = try await connection.request("missing", .null, timeout: .milliseconds(20))
            Issue.record("A dropped reply succeeded")
        } catch let error as LinkError {
            #expect(error.code == "timeout")
        }
        // The old response cannot answer the next request.
        channel.push(Data(#"{"jsonrpc":"2.0","id":1,"result":"late"}"#.utf8))
        let result = try await connection.request("answer", .null, timeout: .seconds(1))
        #expect(result == .string("ok"))
        await connection.close()
    }

    @Test func cancellingAnRPCReleasesItWithoutClosingOtherRequests() async throws {
        let channel = DeadlineChannel()
        let connection = AcpmuxConnection(channel: channel)
        let request = Task { try await connection.request("missing") }
        var sends = channel.sent.makeAsyncIterator()
        _ = await sends.next()
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("A cancelled request succeeded")
        } catch is CancellationError {}
        #expect(channel.closed == false)
        #expect(try await connection.request("answer") == .string("ok"))
        await connection.close()
        do {
            _ = try await connection.request("answer")
            Issue.record("A closed connection accepted a request")
        } catch let error as LinkError { #expect(error.code == "closed") }
    }

    @Test func aMissingPairingChallengeTimesOutAndClosesItsChannel() async throws {
        var pairing = PairInviteTests.pairing(PairInvites())
        pairing.handshakeTimeout = .milliseconds(20)
        let channel = DeadlineChannel()
        let result = await pairing.finish(.success(opened(channel)), macID: "test-mac") {}
        guard case .refused(let error) = result else { Issue.record("Pairing unexpectedly succeeded"); return }
        #expect(error.code == "reply_timeout")
        var closes = channel.closes.makeAsyncIterator()
        _ = await closes.next()
        #expect(channel.closed)
    }

    @Test func approvalCanFinishAfterTheHandshakeDeadline() async throws {
        var pairing = PairInviteTests.pairing(PairInvites())
        // Leave enough room for the first frame to be scheduled while still
        // proving that approval has its own budget after the handshake expires.
        pairing.handshakeTimeout = .seconds(1)
        pairing.approvalTimeout = .seconds(10)
        let channel = DeadlineChannel()
        channel.push(Data(#"{"pending":true}"#.utf8))
        let waiting = AsyncStream<Void>.makeStream()
        let task = Task {
            await pairing.finish(.success(opened(channel)), macID: "test-mac") { waiting.continuation.yield(()) }
        }
        var notices = waiting.stream.makeAsyncIterator()
        _ = await notices.next()
        try await Task.sleep(for: .milliseconds(1100))
        channel.push(Data(#"{"ok":true}"#.utf8))
        #expect(await task.value == .paired(macDevice: "test-mac"))
        waiting.continuation.finish()
    }

    @Test func aMissingApprovalHasAVisibleTimeout() async throws {
        var pairing = PairInviteTests.pairing(PairInvites())
        pairing.approvalTimeout = .milliseconds(20)
        let channel = DeadlineChannel()
        channel.push(Data(#"{"pending":true}"#.utf8))
        let result = await pairing.finish(.success(opened(channel)), macID: "test-mac") {}
        guard case .refused(let error) = result else { Issue.record("Pairing unexpectedly succeeded"); return }
        #expect(error.code == "timeout")
    }

    @Test func cancellingPairingClosesItsWaitingReceive() async throws {
        let pairing = PairInviteTests.pairing(PairInvites())
        let channel = DeadlineChannel()
        let task = Task { await pairing.finish(.success(opened(channel)), macID: "test-mac") {} }
        var reads = channel.reads.makeAsyncIterator()
        _ = await reads.next()
        task.cancel()
        guard case .refused = await task.value else { Issue.record("Cancelled pairing succeeded"); return }
        var closes = channel.closes.makeAsyncIterator()
        _ = await closes.next()
        #expect(channel.closed)
    }

    @Test func eagerWorkspaceSetupWaitsForAuthorizationWithoutAnotherWrite() async throws {
        let channel = DeadlineChannel()
        let prepared = await WorkspaceSync.prepare(channel, deviceID: "phone", deviceName: "iPhone",
                                                   authorizationTimeout: .seconds(1), replyTimeout: .milliseconds(10))
        var writes = channel.sent.makeAsyncIterator()
        let batch = try #require(await writes.next())
        // The normal response budget passes while the Mac's Allow prompt is open.
        try await Task.sleep(for: .milliseconds(30))
        var replies = Data()
        for line in batch.split(separator: 0x0A) {
            let request = try JSONDecoder().decode(JSONValue.self, from: Data(line))
            let id = try #require(request["id"])
            replies.append(try JSONEncoder().encode(JSONValue.object(["id": id, "ok": .bool(true)])))
            replies.append(0x0A)
        }
        channel.push(replies)
        let results = await prepared.replies.value
        #expect(results.count == 5)
        for result in results { _ = try result.get() }
        await prepared.client.close()
        #expect(await writes.next() == nil)
    }

    @Test func eagerWorkspaceSetupStillExpiresWhenAuthorizationNeverCompletes() async throws {
        let channel = DeadlineChannel()
        let prepared = await WorkspaceSync.prepare(channel, deviceID: "phone", deviceName: "iPhone",
                                                   authorizationTimeout: .milliseconds(10), replyTimeout: .milliseconds(10))
        let results = await prepared.replies.value
        #expect(results.count == 5)
        for result in results {
            guard case .failure(let error) = result else { Issue.record("Unanswered setup succeeded"); continue }
            #expect((error as? LinkError)?.code == "reply_timeout")
        }
        await prepared.client.close()
    }

    private func opened(_ channel: DeadlineChannel) -> LinkPairing.Opened {
        .init(channel: channel, identity: "04aa", approval: "04bb", macNonce: "test-nonce")
    }
}

/// Its receive deliberately ignores Task cancellation; only close releases it.
private final class DeadlineChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let lock = NSLock()
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var ended = false
    private let sendEvents = AsyncStream<Data>.makeStream()
    private let readEvents = AsyncStream<Void>.makeStream()
    private let closeEvents = AsyncStream<Void>.makeStream()
    var sent: AsyncStream<Data> { sendEvents.stream }
    var reads: AsyncStream<Void> { readEvents.stream }
    var closes: AsyncStream<Void> { closeEvents.stream }
    var closed: Bool { lock.withLock { ended } }

    func send(_ data: Data) async throws {
        sendEvents.continuation.yield(data)
        if let request = try? JSONDecoder().decode(JSONValue.self, from: data),
           request["method"] == .string("answer"), let id = request["id"] {
            push(try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": .string("ok")])))
        }
    }

    func receive() async throws -> Data? {
        await withCheckedContinuation { continuation in
            let immediate: Data?? = lock.withLock {
                if !queue.isEmpty { return .some(queue.removeFirst()) }
                if ended { return .some(nil) }
                waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
            readEvents.continuation.yield(())
        }
    }

    func push(_ data: Data) {
        let continuation = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
            guard !ended else { return nil }
            if let waiter { self.waiter = nil; return waiter }
            queue.append(data)
            return nil
        }
        continuation?.resume(returning: data)
    }

    func close(code: String, reason: String) async {
        let continuation = lock.withLock {
            ended = true
            defer { waiter = nil; queue = [] }
            return waiter
        }
        continuation?.resume(returning: nil)
        closeEvents.continuation.yield(())
        closeEvents.continuation.finish()
        sendEvents.continuation.finish()
        readEvents.continuation.finish()
    }
}
