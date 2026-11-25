import CmuxMobileAgentChat
import Compression
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

    /// A Mac from before the paged list (it ignores `limit`) answers the first page's watch with
    /// its whole list, uncompressed, in the link's 16 KiB frames, and it may all arrive before
    /// this phone's check of the Mac passed. That answer to the phone's own request is kept
    /// whole: the hub is ready with every chat once the check passes. Before, the budget meant
    /// for notifications cut the list off part way (at about 4 MiB) and dropped it silently.
    @Test func anOlderMacsWholeListBeforePairingArrivesWhole() async throws {
        let rows = 4000
        let channel = OlderMacChannel(rows: rows)
        let hub = AcpmuxHub()
        // The pairing passes once the whole list was read, so all of it came before the check.
        let bind = Task {
            await hub.bind(channel, requestTimeout: .seconds(5), until: {
                while !channel.listRead { try? await Task.sleep(for: .milliseconds(2)) } // test: the list is read first
                return true
            })
        }
        await bind.value
        #expect(channel.listBytes > AcpmuxConnection.MessageJoiner.chunk * 512, "the list is \(channel.listBytes) bytes")
        #expect(hub.isReady, "the hub was not ready after a \(channel.listBytes)-byte list: \(hub.lastError ?? "")")
        #expect(hub.sessions.count == rows)
        #expect(!channel.closed)
        await hub.bind(nil)
    }

    /// A small compressed frame counts at the length it inflates to: one that would inflate past
    /// the budget is refused before it is inflated, and the channel closes.
    @Test func aSmallCompressedFrameThatInflatesPastTheBudgetIsCutOff() async throws {
        let text = Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"text":"\#(String(repeating: "a", count: 20 << 20))"}}"#.utf8)
        let envelope = try #require(Self.deflated(text))
        #expect(envelope.count < 256 << 10, "the envelope is \(envelope.count) bytes")
        let channel = FramesChannel([envelope])
        let connection = AcpmuxConnection(channel: channel, held: true)
        await connection.start()
        let end = ContinuousClock.now + .seconds(10)
        while !channel.closed, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5)) // test: waits for the reader
        }
        #expect(channel.closed, "a \(envelope.count)-byte frame of \(text.count) bytes inflated was kept before pairing")
        #expect(await connection.heldByteCount <= AcpmuxConnection.heldByteLimit + envelope.count)
    }

    /// A plain notification is held to the budget while its frames arrive: one longer than what
    /// is left is cut off before it is all read or parsed, not after it was put together.
    @Test func aPlainNotificationPastTheBudgetIsCutOffWhileItArrives() async throws {
        let text = Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"text":"\#(String(repeating: "a", count: 12 << 20))"}}"#.utf8)
        let frames = Self.split(text)
        let channel = FramesChannel(frames)
        let connection = AcpmuxConnection(channel: channel, held: true)
        await connection.start()
        let end = ContinuousClock.now + .seconds(20)
        while !channel.closed, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5)) // test: waits for the reader
        }
        #expect(channel.closed, "a \(text.count)-byte notification was kept before pairing")
        #expect(channel.read < frames.count, "all \(frames.count) frames were read and joined before the cut")
        #expect(channel.read <= AcpmuxConnection.heldByteLimit / AcpmuxConnection.MessageJoiner.chunk + 2)
    }

    /// The answer to one of this phone's own requests may be larger than the budget, compressed
    /// or not (an older Mac's whole list, a first page with tools on): it is kept whole and
    /// handed over once the check passed.
    @Test func aCompressedAnswerPastTheBudgetIsKept() async throws {
        let pad = 20 << 20
        let channel = AnsweringChannel { id in
            let text = Data(#"{"id":\#(id),"jsonrpc":"2.0","result":{"pad":"\#(String(repeating: "a", count: pad))"}}"#.utf8)
            guard let envelope = AcpmuxHeldBeforePairingTests.deflated(text) else { return [] }
            return AcpmuxHeldBeforePairingTests.split(envelope)
        }
        let connection = AcpmuxConnection(channel: channel, held: true)
        await connection.start()
        let id = try await connection.submit("_acpmux/watch", .object([:]))
        let end = ContinuousClock.now + .seconds(20)
        while !channel.allRead, !channel.closed, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5)) // test: waits for the reader
        }
        #expect(!channel.closed, "the answer to this phone's own request was refused")
        await connection.admit()
        let reply = try await connection.reply(to: id)
        #expect(reply["pad"]?.stringValue?.utf8.count == pad)
        await connection.close()
    }

    /// `data` in the link's 16 KiB frames.
    nonisolated static func split(_ data: Data) -> [Data] {
        let chunk = AcpmuxConnection.MessageJoiner.chunk
        return stride(from: 0, to: data.count, by: chunk).map { data.subdata(in: $0..<min($0 + chunk, data.count)) }
    }

    /// The mobile host's envelope (`DeflatedMessage`): 0x00, text length, deflate length, raw deflate.
    nonisolated static func deflated(_ text: Data) -> Data? {
        var body = Data(count: text.count / 100 + 4096)
        let written = body.withUnsafeMutableBytes { out -> Int in
            text.withUnsafeBytes { input -> Int in
                guard let dst = out.bindMemory(to: UInt8.self).baseAddress,
                      let src = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dst, out.count, src, text.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        body.count = written
        func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) } }
        return Data([DeflatedMessage.marker] + u32(text.count) + u32(written)) + body
    }
}

/// A Mac from before the paged list: `initialize` answers at once, and `_acpmux/watch` answers
/// with every one of `rows` chats (about 2.7 KB each, like a real row), uncompressed, split into
/// the link's 16 KiB frames.
private final class OlderMacChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let lock = NSLock()
    private let rows: Int
    private var queue: [Data] = []
    private var listQueued = false
    private var ended = false
    private(set) var listBytes = 0

    init(rows: Int) { self.rows = rows }

    var closed: Bool { lock.withLock { ended } }
    /// The whole list was queued and read.
    var listRead: Bool { lock.withLock { listQueued && queue.isEmpty } }

    func send(_ data: Data) async throws {
        guard let request = try? JSONDecoder().decode(JSONValue.self, from: data),
              let id = request["id"]?.numberValue, let method = request["method"]?.stringValue else { return }
        let reply: String
        switch method {
        case "initialize":
            reply = #"{"jsonrpc":"2.0","id":\#(Int(id)),"result":{}}"#
        case "_acpmux/watch":
            let preview = String(repeating: "p", count: 2600)
            let sessions = (0..<rows).map { #"{"sessionId":"s\#($0)","name":"chat \#($0)","status":"idle","preview":"\#(preview)"}"# }
            reply = #"{"jsonrpc":"2.0","id":\#(Int(id)),"result":{"sessions":[\#(sessions.joined(separator: ","))]}}"#
        default:
            return
        }
        let bytes = Data(reply.utf8)
        let chunk = AcpmuxConnection.MessageJoiner.chunk
        let frames = stride(from: 0, to: bytes.count, by: chunk).map { bytes.subdata(in: $0..<min($0 + chunk, bytes.count)) }
        lock.withLock {
            queue += frames
            if method == "_acpmux/watch" {
                listBytes = bytes.count
                listQueued = true
            }
        }
    }

    func receive() async throws -> Data? {
        while true {
            let next: Data?? = lock.withLock {
                if ended { return .some(nil) }
                return queue.isEmpty ? nil : .some(queue.removeFirst())
            }
            if let next { return next }
            try await Task.sleep(for: .milliseconds(2)) // test: a Mac with nothing more to say
        }
    }

    func close(code: String, reason: String) async { lock.withLock { ended = true } }
}

/// A Mac that sends `frames`, then goes quiet.
private final class FramesChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let lock = NSLock()
    private var frames: [Data]
    private var count = 0
    private var ended = false

    init(_ frames: [Data]) { self.frames = frames }

    var closed: Bool { lock.withLock { ended } }
    /// Frames the phone read.
    var read: Int { lock.withLock { count } }

    func send(_ data: Data) async throws {}

    func receive() async throws -> Data? {
        while true {
            let next: Data?? = lock.withLock {
                if ended { return .some(nil) }
                guard !frames.isEmpty else { return nil }
                count += 1
                return .some(frames.removeFirst())
            }
            if let next { return next }
            try await Task.sleep(for: .milliseconds(5)) // test: a Mac that went quiet
        }
    }

    func close(code: String, reason: String) async { lock.withLock { ended = true } }
}

/// A Mac that answers each request with the frames `answer` makes for its id.
private final class AnsweringChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let lock = NSLock()
    private let answer: @Sendable (Int) -> [Data]
    private var queue: [Data] = []
    private var answered = 0
    private var ended = false

    init(answer: @escaping @Sendable (Int) -> [Data]) { self.answer = answer }

    var closed: Bool { lock.withLock { ended } }
    /// Every answer was queued and read.
    var allRead: Bool { lock.withLock { answered > 0 && queue.isEmpty } }

    func send(_ data: Data) async throws {
        guard let request = try? JSONDecoder().decode(JSONValue.self, from: data),
              let id = request["id"]?.numberValue else { return }
        let frames = answer(Int(id))
        lock.withLock {
            queue += frames
            answered += 1
        }
    }

    func receive() async throws -> Data? {
        while true {
            let next: Data?? = lock.withLock {
                if ended { return .some(nil) }
                return queue.isEmpty ? nil : .some(queue.removeFirst())
            }
            if let next { return next }
            try await Task.sleep(for: .milliseconds(2)) // test: a Mac with nothing more to say
        }
    }

    func close(code: String, reason: String) async { lock.withLock { ended = true } }
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
