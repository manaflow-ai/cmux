import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The chats' channel opens before this phone checked the Mac (ask-48f698fc26). A peer that
/// never passes the check must not fill the phone's memory while the check waits.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AcpmuxHeldBeforePairingTests {
    @Test func aPeerFloodingNotificationsBeforePairingIsCutOff() async throws {
        let channel = FloodChannel(limit: 50_000)
        let hub = AcpmuxHub()
        // The pairing's verdict, held back until the flood was judged (as `passed` in finishServing).
        let check = AsyncStream<Bool>.makeStream()
        let passed = Task<Bool, Never> {
            var results = check.stream.makeAsyncIterator()
            return await results.next() ?? false
        }
        let bind = Task { await hub.bind(channel, until: { await passed.value }) }
        let end = ContinuousClock.now + .seconds(20)
        while !channel.closed, channel.read < 50_000, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5)) // test: waits for the reader
        }
        #expect(channel.closed, "the channel stayed open after \(channel.read) notifications before pairing")
        #expect(channel.read <= AcpmuxConnection.heldNotificationLimit + 8,
                "read \(channel.read) notifications before pairing")
        check.continuation.yield(false)
        check.continuation.finish()
        await bind.value
        #expect(!hub.isReady)
    }

    @Test func whatWaitedForTheCheckGoesOutOnlyAfterIt() async throws {
        let channel = FloodChannel(limit: 3)
        let connection = AcpmuxConnection(channel: channel, held: true)
        await connection.start()
        let end = ContinuousClock.now + .seconds(5)
        while channel.read < 3, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5)) // test: waits for the reader
        }
        let early = Task { () -> Int in
            var count = 0
            for await _ in connection.notifications { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(50)) // test: a notification out before admit would be counted
        await connection.admit()
        channel.end()
        #expect(await early.value == 3)
        #expect(!channel.closed)
    }
}

/// A Mac that sends `_acpmux/event` notifications as fast as they are read, up to `limit`.
private final class FloodChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let lock = NSLock()
    private let limit: Int
    private var count = 0
    private var ended = false
    private var finished = false
    private static let event = Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s1","seq":1,"record":{"kind":"x","text":"\#(String(repeating: "a", count: 512))"}}}"#.utf8)

    init(limit: Int) { self.limit = limit }

    var read: Int { lock.withLock { count } }
    var closed: Bool { lock.withLock { ended } }

    func send(_ data: Data) async throws {}

    func receive() async throws -> Data? {
        while true {
            let next: Data?? = lock.withLock {
                if ended || finished { return .some(nil) }
                guard count < limit else { return nil }
                count += 1
                return .some(Self.event)
            }
            if let next { return next }
            try await Task.sleep(for: .milliseconds(5)) // test: a Mac that went quiet after its flood
        }
    }

    /// The Mac closes its side once what it sent was read.
    func end() { lock.withLock { finished = true } }

    func close(code: String, reason: String) async { lock.withLock { ended = true } }
}
