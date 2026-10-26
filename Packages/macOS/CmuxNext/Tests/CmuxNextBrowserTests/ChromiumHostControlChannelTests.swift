#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import Darwin
import Testing

/// The control channel to the Chromium host: the same golden frame as
/// ChromiumHost/tests/chromium_host_control_test.cpp
/// (scripts/cmux-next/tests/chromium-host-wire.test.sh), the malformed-frame
/// rules, the outbox's coalescing, and channels on a real socket pair.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ChromiumHostControlChannelTests {
    typealias Message = ChromiumHostControlMessage

    static let golden: [UInt8] = hexBytes(
        "2d00000003020800efbeadde01010400feffffff020208000807060504030201"
            + "03030800000000000000f83f0404020000ff0505030068c3a9")

    static let goldenMessage = Message(
        op: 0x0203, token: 0xdeadbeef, isReply: true,
        fields: [.init(tag: 1, value: .i32(-2)), .init(tag: 2, value: .i64(0x0102030405060708)),
                 .init(tag: 3, value: .f64(1.5)), .init(tag: 4, value: .bytes([0, 255])), .init(tag: 5, value: .str("hé"))])

    static func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    static func geometry(_ browser: Int32, _ width: Int32) -> Message {
        Message(op: 2, fields: [.init(tag: 1, value: .i32(browser)), .init(tag: 2, value: .i32(width))])
    }

    static func key(_ browser: Int32, _ code: Int32) -> Message {
        Message(op: 5, fields: [.init(tag: 1, value: .i32(browser)), .init(tag: 2, value: .i32(code))])
    }

    static func decode(_ bytes: ArraySlice<UInt8>) -> Message.Decoded {
        var fds: [Int32] = []
        return Message.decode(bytes, fds: &fds)
    }

    static func codes(_ range: Range<Int>) -> [Message.Value?] {
        range.map { Optional(Message.Value.i32(Int32($0))) }
    }

    /// The host end's channel, for its own message handler to answer on.
    final class PeerSlot {
        var channel: ChromiumHostControlChannel?
    }

    static func socketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    /// What one channel delivered to main, as a stream the test awaits.
    final class Recorder {
        enum Event: Sendable {
            case messages([Message])
            case end(ChromiumHostControlEnd)
        }

        let events: AsyncStream<Event>
        private let continuation: AsyncStream<Event>.Continuation
        var messages: [Message] = []
        var batches = 0
        var end: ChromiumHostControlEnd?

        init() {
            let (events, continuation) = AsyncStream<Event>.makeStream()
            self.events = events
            self.continuation = continuation
        }

        func channel(fd: Int32, options: ChromiumHostControlChannel.Options = .init(),
                     onMessage: (@MainActor @Sendable (Message) -> Void)? = nil) -> ChromiumHostControlChannel {
            let continuation = continuation
            return ChromiumHostControlChannel(
                fd: fd, options: options, post: { drain in Task { @MainActor in drain() } },
                onMessages: { batch in
                    for message in batch { onMessage?(message) }
                    continuation.yield(.messages(batch))
                },
                onEnd: { continuation.yield(.end($0)) })
        }

        /// Takes events until `done`.
        func wait(until done: () -> Bool) async {
            if done() { return }
            for await event in events {
                switch event {
                case .messages(let batch):
                    batches += 1
                    messages += batch
                case .end(let reason):
                    end = reason
                }
                if done() { return }
            }
        }
    }

    // MARK: Frames

    @Test func encodesTheGoldenFrame() {
        #expect(Self.goldenMessage.encoded() == Self.golden)
    }

    @Test func decodesTheGoldenFrame() {
        let bytes = Self.golden + [9, 9]
        #expect(Self.decode(bytes[...]) == .frame(Self.goldenMessage, consumed: Self.golden.count))
        #expect(Self.decode(Self.golden.dropLast()) == .needMore)
        #expect(Self.goldenMessage[5] == .str("hé"))
        #expect(Self.goldenMessage[9] == nil)
    }

    @Test func refusesMalformedFrames() {
        var tooLong = Array(Self.golden.prefix(Message.headerSize))
        withUnsafeBytes(of: UInt32(Message.maxBody + 1).littleEndian) { tooLong.replaceSubrange(0..<4, with: $0) }
        #expect(Self.decode(tooLong[...]) == .malformed, "a length over the limit, before its body arrives")
        func with(_ offset: Int, _ value: UInt8) -> ArraySlice<UInt8> {
            var bytes = Self.golden
            bytes[offset] = value
            return bytes[...]
        }
        #expect(Self.decode(with(7, 0x01)) == .malformed, "an unknown flag")
        #expect(Self.decode(with(6, 0x0d)) == .malformed, "more than four descriptors")
        #expect(Self.decode(with(6, 0x09)) == .malformed, "a descriptor that did not arrive")
        #expect(Self.decode(with(12, 9)) == .malformed, "an unknown type")
        #expect(Self.decode(with(14, 3)) == .malformed, "an i32 of three bytes")
        #expect(Self.decode(with(52, 0x30)) == .malformed, "a field past the body")
        #expect(Self.decode(with(55, 0xff)) == .malformed, "bad UTF-8 in a str")
        let big = Message(op: 1, fields: [.init(tag: 1, value: .bytes(Array(repeating: 1, count: 60_000))),
                                          .init(tag: 2, value: .bytes(Array(repeating: 2, count: 6_000)))])
        #expect(big.encoded() == nil, "a body over 64 KiB is never sent")
    }

    // MARK: Outbox

    @Test func outboxKeepsOneStateOpPerPageAndEveryKeyInOrder() {
        var outbox = ChromiumHostControlOutbox(quotaBytes: 1 << 20, quotaMessages: 8)
        let page1 = ChromiumHostControlChannel.stateKey(op: 2, browser: 1)
        let page2 = ChromiumHostControlChannel.stateKey(op: 2, browser: 2)
        for index in 0..<1_000 {
            outbox.push([UInt8](repeating: 1, count: 16), fds: [], key: page1)
            outbox.push([UInt8](repeating: 2, count: 16), fds: [], key: page2)
            if index % 100 == 0 { outbox.push([UInt8](repeating: UInt8(100 + index / 100), count: 16), fds: [], key: nil) }
        }
        #expect(outbox.count(key: page1) == 1 && outbox.count(key: page2) == 1)
        #expect(outbox.messages == 12)
        #expect(outbox.isOverQuota)
        var order: [UInt8] = []
        var sends = 0
        let flushed = outbox.flush { bytes, _ in
            sends += 1
            order += stride(from: 0, to: bytes.count, by: 16).map { bytes[$0] }
            return .wrote(bytes.count)
        }
        #expect(flushed == .drained)
        #expect(order == [100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 1, 2], "keys keep their order; the newest geometry follows them")
        #expect(sends == 1, "small frames go in one sendmsg")
        #expect(outbox.isEmpty && outbox.bytes == 0)

        outbox.push([UInt8](repeating: 1, count: 16), fds: [], key: page1)
        let partly = outbox.flush { _, _ in .wrote(4) }
        #expect(partly == .blocked)
        let replaced = outbox.push([UInt8](repeating: 3, count: 16), fds: [], key: page1)
        #expect(!replaced, "a partly written state op is never replaced")
        #expect(outbox.messages == 2)
        #expect(outbox.count(key: page1) == 1, "the partly written one is in flight, not waiting")
        let replacedWaiting = outbox.push([UInt8](repeating: 4, count: 16), fds: [], key: page1)
        #expect(replacedWaiting, "a newer one replaces the waiting one")
        #expect(outbox.count(key: page1) == 1 && outbox.messages == 2, "one in flight and one waiting per page")
        outbox.removeAll()
    }

    @Test func aFrameWithDescriptorsStartsABatch() throws {
        var outbox = ChromiumHostControlOutbox(quotaBytes: 1 << 20, quotaMessages: 4_096)
        var pipeFDs: [Int32] = [-1, -1]
        try #require(pipe(&pipeFDs) == 0 && fcntl(pipeFDs[0], F_SETFL, O_NONBLOCK) == 0)
        for _ in 0..<3 { outbox.push([UInt8](repeating: 1, count: 16), fds: [], key: nil) }
        outbox.push([UInt8](repeating: 2, count: 16), fds: [dup(pipeFDs[1])], key: nil)
        for _ in 0..<100 { outbox.push([UInt8](repeating: 3, count: 16), fds: [], key: nil) }
        var batches: [(bytes: Int, fds: Int, first: UInt8)] = []
        let flushed = outbox.flush { bytes, fds in
            batches.append((bytes.count, fds.count, bytes[0]))
            return .wrote(bytes.count)
        }
        #expect(flushed == .drained)
        #expect(batches.map { $0.bytes } == [48, 16 * 101] && batches.map { $0.fds } == [0, 1]
                    && batches.map { $0.first } == [1, 2],
                "the frames before the one with a descriptor go together; it leads the next batch")
        close(pipeFDs[1])
        var byte: UInt8 = 0
        #expect(read(pipeFDs[0], &byte, 1) == 0, "the sent descriptor was closed once it went")
        close(pipeFDs[0])
    }

    // MARK: Channels on a socket pair

    @Test func framesAndDescriptorsCrossInOrderAndInBatches() async throws {
        let (aFD, bFD) = try Self.socketPair()
        let a = Recorder(), b = Recorder()
        let sender = a.channel(fd: aFD)
        let receiver = b.channel(fd: bFD)
        var pipeFDs: [Int32] = [-1, -1]
        try #require(pipe(&pipeFDs) == 0)
        var first = Self.goldenMessage
        first.isReply = false
        first.fds = [pipeFDs[1]]
        #expect(sender.send(first))
        close(pipeFDs[1])  // the channel sent its own duplicate
        for code in 0..<100 { #expect(sender.send(Self.key(1, Int32(code)))) }
        await b.wait { b.messages.count == 101 }
        #expect(b.messages[0].fields == Self.goldenMessage.fields)
        #expect(b.messages[0].fds.count == 1, "the descriptor arrives with its frame")
        if let received = b.messages[0].fds.first {
            var byte: UInt8 = 0x78
            let written = write(received, &byte, 1)
            close(received)
            byte = 0
            let readCount = read(pipeFDs[0], &byte, 1)
            #expect(written == 1 && readCount == 1 && byte == 0x78, "the received descriptor writes into the pipe")
        }
        close(pipeFDs[0])
        #expect(b.messages.dropFirst().map { $0[2] } == Self.codes(0..<100), "keys arrive in order")
        #expect(b.batches < 101, "messages reach main in batches, not one task each")
        sender.close()
        await b.wait { b.end != nil }
        #expect(b.end == .peerClosed)
        #expect(!receiver.send(Self.key(1, 1)), "an ended channel sends nothing")
    }

    @Test func aBadLengthEndsTheConnection() async throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        let channel = recorder.channel(fd: fd)
        var bytes = try #require(Self.key(1, 7).encoded())
        var header = [UInt8](repeating: 0, count: Message.headerSize)
        withUnsafeBytes(of: UInt32(Message.maxBody + 1).littleEndian) { header.replaceSubrange(0..<4, with: $0) }
        bytes += header
        let written = write(peer, bytes, bytes.count)
        #expect(written == bytes.count)
        await recorder.wait { recorder.end != nil }
        #expect(recorder.end == .malformed)
        #expect(recorder.messages.count == 1, "the good frame before it is delivered first")
        var byte: UInt8 = 0
        let readCount = read(peer, &byte, 1)
        #expect(readCount == 0, "the host reads EOF")
        #expect(!channel.send(Self.key(1, 1)))
        close(peer)
    }

    @Test func aPeerThatNeverReadsLeavesCmuxUnblockedWithGeometryCoalesced() async throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        let channel = recorder.channel(fd: fd)
        let page1 = ChromiumHostControlChannel.stateKey(op: 2, browser: 1)
        let page2 = ChromiumHostControlChannel.stateKey(op: 2, browser: 2)
        let clock = ContinuousClock()
        var allSent = true
        let took = clock.measure {
            for index in 0..<20_000 {
                allSent = channel.send(Self.geometry(1, Int32(index)), stateKey: page1) && allSent
                allSent = channel.send(Self.geometry(2, Int32(index)), stateKey: page2) && allSent
                if index % 2 == 0 { allSent = channel.send(Self.key(1, Int32(index))) && allSent }
            }
        }
        #expect(allSent, "every send is taken while the host never reads")
        #expect(took < .seconds(2), "no send waits for the host")
        #expect(channel.pendingCount(stateKey: page1) == 1 && channel.pendingCount(stateKey: page2) == 1,
                "geometry waits as one per page")
        let stats = channel.stats
        #expect(stats.coalesced > 0)
        #expect(stats.quotaExcess > 0, "the excess over quota is counted, and ends nothing")

        // The host reads at last: every key arrives, in order, and the newest
        // geometry of each page comes after them.
        let host = Recorder()
        let hostChannel = host.channel(fd: peer)
        await host.wait {
            let last = host.messages.suffix(2)
            return last.count == 2 && last.allSatisfy { $0.op == 2 && $0[2] == .i32(19_999) }
        }
        let keys = host.messages.filter { $0.op == 5 }.map { $0[2] }
        #expect(keys == stride(from: 0, to: 20_000, by: 2).map { Optional(Message.Value.i32(Int32($0))) },
                "every key arrives, in order")
        let lastWidth = { (page: Int32) in host.messages.last { $0.op == 2 && $0[1] == .i32(page) }?[2] }
        #expect(lastWidth(1) == .i32(19_999) && lastWidth(2) == .i32(19_999), "the newest geometry of each page is the last one")
        #expect(recorder.end == nil && host.end == nil)
        channel.close()
        hostChannel.close()
    }

    @Test func theHostClosingWhileFramesWaitEndsAsPeerClosed() async throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        let channel = recorder.channel(fd: fd)
        var code: Int32 = 0
        while channel.stats.pendingMessages == 0, code < 1_000_000 {
            channel.send(Self.key(1, code))
            code += 1
        }
        #expect(channel.stats.pendingMessages > 0, "frames wait in the outbox")
        close(peer)
        await recorder.wait { recorder.end != nil }
        #expect(recorder.end == .peerClosed, "the host quit; the socket did not break")
        #expect(!channel.send(Self.key(1, 1)))
    }

    @Test func aDescriptorOnAFrameThatDeclaresNoneIsMalformed() async throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        let channel = recorder.channel(fd: fd)
        var pipeFDs: [Int32] = [-1, -1]
        try #require(pipe(&pipeFDs) == 0 && fcntl(pipeFDs[0], F_SETFL, O_NONBLOCK) == 0)
        let frame = try #require(Self.key(1, 7).encoded())
        let sent = frame.withUnsafeBytes { ChromiumHostControlSocket(fd: peer).send($0, fds: [pipeFDs[1]]) }
        #expect(sent == .wrote(frame.count))
        close(pipeFDs[1])
        await recorder.wait { recorder.end != nil }
        #expect(recorder.end == .malformed)
        var byte: UInt8 = 0
        #expect(read(pipeFDs[0], &byte, 1) == 0, "the stray descriptor is closed, not given to a later frame")
        close(pipeFDs[0])
        #expect(!channel.send(Self.key(1, 1)))
        close(peer)
    }

    @Test func theCeilingSparesAnOutboxThatCoalescingBroughtUnderQuota() async throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        var options = ChromiumHostControlChannel.Options()
        options.quotaBytes = 32 * 1024
        options.quotaCeiling = .milliseconds(50)
        let channel = recorder.channel(fd: fd, options: options)
        var code: Int32 = 0
        while channel.stats.pendingMessages == 0, code < 1_000_000 {
            channel.send(Self.key(1, code))
            code += 1
        }
        let page1 = ChromiumHostControlChannel.stateKey(op: 2, browser: 1)
        var big = Self.geometry(1, 1)
        big.fields.append(.init(tag: 3, value: .bytes(Array(repeating: 0x73, count: 60_000))))
        #expect(channel.send(big, stateKey: page1))
        #expect(channel.stats.quotaExcess > 0, "a large waiting state op is over quota")
        #expect(channel.send(Self.geometry(1, 2), stateKey: page1))
        #expect(channel.stats.pendingBytes < options.quotaBytes, "its replacement is under quota")
        // A fixed wait past the ceiling's one deadline, not a poll: the reader wakes at it.
        try await Task.sleep(for: .milliseconds(200))
        #expect(channel.send(Self.key(1, 1)), "past the ceiling the channel still sends")
        channel.close()
        close(peer)
    }

    @Test func overQuotaForTheWholeCeilingEndsTheConnection() async throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        var options = ChromiumHostControlChannel.Options()
        options.quotaMessages = 4
        options.quotaCeiling = .milliseconds(50)
        let channel = recorder.channel(fd: fd, options: options)
        let big = Message(op: 9, fields: [.init(tag: 1, value: .bytes(Array(repeating: 0x7a, count: 60_000)))])
        for _ in 0..<64 { channel.send(big) }
        #expect(channel.stats.quotaExcess > 0)
        await recorder.wait { recorder.end != nil }
        #expect(recorder.end == .quotaCeiling)
        close(peer)
    }

    @Test func aRequestResumesWithItsReplyAndEndsWithTheHost() async throws {
        let (fd, peerFD) = try Self.socketPair()
        let cmux = Recorder(), host = Recorder()
        let channel = cmux.channel(fd: fd)
        let slot = PeerSlot()
        let peer = host.channel(fd: peerFD) { request in
            guard request.op == 2 else { return }  // op 99 is never answered
            let reply = Message(op: request.op, token: request.token, isReply: true,
                                fields: [.init(tag: 1, value: request[2] ?? .i32(0))])
            slot.channel?.send(reply)
        }
        slot.channel = peer
        let reply = try await channel.request(Self.geometry(3, 640))
        #expect(reply.isReply && reply[1] == .i32(640))

        let unanswered = Task { try await channel.request(Message(op: 99)) }
        await host.wait { host.messages.contains { $0.op == 99 } }
        peer.close()
        let result = await unanswered.result
        #expect(throws: ChromiumHostControlError.hostGone(.peerClosed), "a waiting request resumes when the host ends") {
            try result.get()
        }
        await cmux.wait { cmux.end != nil }
        await #expect(throws: ChromiumHostControlError.hostGone(.peerClosed), "a request after the end throws at once") {
            try await channel.request(Self.geometry(3, 1))
        }
    }

    @Test func anUnaskedReplyIsMalformed() async throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        let channel = recorder.channel(fd: fd)
        let bytes = try #require(Message(op: 1, token: 77, isReply: true).encoded())
        let written = write(peer, bytes, bytes.count)
        #expect(written == bytes.count)
        await recorder.wait { recorder.end != nil }
        #expect(recorder.end == .malformed)
        #expect(!channel.send(Self.key(1, 1)))
        close(peer)
    }

    @Test func aPausedReaderReadsAgainAfterEachDrain() async throws {
        let (aFD, bFD) = try Self.socketPair()
        let a = Recorder(), b = Recorder()
        let sender = a.channel(fd: aFD)
        var options = ChromiumHostControlChannel.Options()
        options.inboxLimit = 4
        let receiver = b.channel(fd: bFD, options: options)
        for code in 0..<5_000 { sender.send(Self.key(1, Int32(code))) }
        await b.wait { b.messages.count == 5_000 }
        #expect(b.messages.map { $0[2] } == Self.codes(0..<5_000))
        sender.close()
        receiver.close()
    }
}
#endif
