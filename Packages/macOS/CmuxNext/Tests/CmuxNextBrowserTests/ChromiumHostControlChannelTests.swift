#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import Darwin
import Testing

/// The control channel to the Chromium host: the same golden frame as
/// ChromiumHost/tests/chromium_host_control_test.cpp
/// (scripts/cmux-next/tests/chromium-host-wire.test.sh), the malformed-frame
/// rules, the outbox's coalescing, channels on a real socket pair, and
/// payloads over 64 KiB in shared memory (task 020).
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
        /// The most payload bytes one drain delivered.
        var largestBatchBytes = 0
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
                    var messages: [Message] = []
                    for message in batch {
                        onMessage?(message)
                        messages.append(message)
                    }
                    continuation.yield(.messages(messages))
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
                    largestBatchBytes = max(largestBatchBytes, batch.reduce(0) { $0 + $1.payloadByteCount })
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

    /// Task 091: every request still waiting when the host closes its end resumes with hostGone, and
    /// none stays in the channel.
    @Test func fiftyWaitingRequestsResumeWhenTheHostEnds() async throws {
        let (fd, peerFD) = try Self.socketPair()
        let cmux = Recorder(), host = Recorder()
        let channel = cmux.channel(fd: fd)
        let peer = host.channel(fd: peerFD)  // answers nothing
        let requests = (0..<50).map { index in
            Task { try await channel.request(Message(op: 99, fields: [.init(tag: 1, value: .i32(Int32(index)))])) }
        }
        await host.wait { host.messages.count >= 50 }
        #expect(channel.stats.awaitingReplies == 50)

        peer.close()
        var gone = 0
        for request in requests {
            do {
                _ = try await request.value
            } catch let error as ChromiumHostControlError where error == .hostGone(.peerClosed) {
                gone += 1
            } catch {}
        }

        #expect(gone == 50, "a request waiting on the ended host resumed otherwise, or not at all")
        #expect(channel.stats.awaitingReplies == 0, "the ended channel kept a request's continuation")
        await cmux.wait { cmux.end != nil }
        #expect(cmux.end == .peerClosed)
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

    // MARK: Large payloads (task 020)

    static func pattern(_ count: Int, seed: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) }
    }

    /// A page resource body of 10 MB, with a 70 KB PNG and a 200 KB string beside it.
    static let largeResource = Message(
        op: 0x0301,
        fields: [.init(tag: 1, value: .i32(42)), .init(tag: 2, value: .str("text/html; charset=utf-8")),
                 .init(tag: 3, value: .bytes(pattern(10 * 1024 * 1024, seed: 7))),
                 .init(tag: 4, value: .bytes(pattern(70_000, seed: 3))),
                 .init(tag: 5, value: .str(String(repeating: "a", count: 200_000)))])

    @Test func fieldsTooLargeForAFrameAreChosenForSharedMemory() {
        #expect(Self.largeResource.sharedFieldIndices() == [2, 3, 4], "every field over 65,535 bytes")
        let fitting = Message(op: 1, fields: [.init(tag: 1, value: .bytes(Array(repeating: 1, count: 40_000))),
                                              .init(tag: 2, value: .bytes(Array(repeating: 2, count: 30_000))),
                                              .init(tag: 3, value: .bytes(Array(repeating: 3, count: 20_000)))])
        #expect(fitting.sharedFieldIndices() == [0], "then the largest until the body fits 64 KiB")
        #expect(Self.goldenMessage.sharedFieldIndices().isEmpty, "a frame that fits shares nothing")
        var tooMany = Self.largeResource
        tooMany.fields += [.init(tag: 6, value: .bytes(Array(repeating: 6, count: 70_000))),
                           .init(tag: 7, value: .bytes(Array(repeating: 7, count: 70_000)))]
        #expect(tooMany.encoded(sharing: tooMany.sharedFieldIndices()) == nil, "more regions than descriptors is never sent")
    }

    @Test func aTenMegabyteResourceRoundTrips() async throws {
        let (aFD, bFD) = try Self.socketPair()
        let a = Recorder(), b = Recorder()
        let sender = a.channel(fd: aFD)
        let receiver = b.channel(fd: bFD)
        var pipeFDs: [Int32] = [-1, -1]
        try #require(pipe(&pipeFDs) == 0)
        var resource = Self.largeResource
        resource.fds = [pipeFDs[1]]
        #expect(sender.send(resource))
        close(pipeFDs[1])
        #expect(sender.send(Self.key(1, 1)))
        await b.wait { b.messages.count == 2 }
        #expect(b.messages[0].fields == Self.largeResource.fields, "the 10 MB resource arrives byte for byte")
        #expect(b.messages[0].fds.count == 1, "the caller's descriptor arrives; the regions are read and closed")
        for received in b.messages[0].fds { close(received) }
        #expect(b.messages[1].op == 5, "the key after it follows it")
        close(pipeFDs[0])
        sender.close()
        receiver.close()
    }

    @Test func noSocketMessageIsOver64KiB() throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        let channel = recorder.channel(fd: fd)
        #expect(channel.send(Self.largeResource))
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        var control = [UInt8](repeating: 0, count: ChromiumHostControlSocket.receiveControlSize)
        var fds: [Int32] = []
        var raw: [UInt8] = []
        let socket = ChromiumHostControlSocket(fd: peer)
        // send wrote the frame before it returned (the outbox was empty): read all the socket holds.
        try #require(fcntl(peer, F_SETFL, O_NONBLOCK) == 0)
        while case .read(let count) = socket.receive(into: &chunk, control: &control, fds: &fds) {
            raw += chunk[0..<count]
        }
        #expect(raw.count <= Message.headerSize + Message.maxBody, "the socket carries no message over 64 KiB")
        #expect(fds.count == 3, "one region per large field")
        for region in fds {
            var probe: UInt8 = 0
            let written = write(region, &probe, 1)
            #expect(written < 0, "the receiver cannot write a region")
            #expect(fcntl(region, F_GETFL) & O_ACCMODE == O_RDONLY, "a region is read-only")
        }
        let decoded = Message.decode(raw[...], fds: &fds)
        #expect(decoded == .frame(Self.largeResource, consumed: raw.count), "the frame decodes with its regions read")
        #expect(fds.isEmpty, "and the regions are taken")
        channel.close()
        close(peer)
    }

    @Test func aSharedFieldWithABadRegionIsMalformed() throws {
        let message = Message(op: 7, fields: [.init(tag: 1, value: .bytes(Array(repeating: 0x72, count: 70_000)))])
        let frame = try #require(message.encoded(sharing: [0]))
        func decode(with fd: Int32) -> Message.Decoded {
            var fds = [fd]
            return Message.decode(frame[...], fds: &fds)
        }
        // decode closes every region it takes (chromium_host_control_test.cpp checks the numbers; tests
        // here run in parallel, so a closed number may be reused at once).
        let good = try #require(ChromiumHostSharedRegion(holding: message.payload(at: 0)))
        #expect(decode(with: good.fd) == .frame(message, consumed: frame.count), "a read-only region of the right size")
        let short = try #require(ChromiumHostSharedRegion(holding: [1, 2, 3]))
        #expect(decode(with: short.fd) == .malformed, "a region shorter than its count")

        var pipeFDs: [Int32] = [-1, -1]
        try #require(pipe(&pipeFDs) == 0 && fcntl(pipeFDs[0], F_SETFL, O_NONBLOCK) == 0)
        #expect(decode(with: pipeFDs[1]) == .malformed, "a writable descriptor its sender could change")
        var byte: UInt8 = 0
        let readCount = read(pipeFDs[0], &byte, 1)
        #expect(readCount == 0, "is closed: the pipe has no writer left")
        close(pipeFDs[0])

        var zero = frame
        zero.replaceSubrange((Message.headerSize + Message.fieldHeaderSize)..<(Message.headerSize + Message.fieldHeaderSize + 8),
                             with: [UInt8](repeating: 0, count: 8))
        let one = try #require(ChromiumHostSharedRegion(holding: [1]))
        var fds = [one.fd]
        #expect(Message.decode(zero[...], fds: &fds) == .malformed, "a shared field of 0 bytes")
        for fd in fds { close(fd) }
    }

    /// A host could send a read-only descriptor of a file it can still
    /// truncate through another descriptor: the copy would then fault. Only a
    /// shm object, which xnu sizes once, is mapped.
    @Test func aReadOnlyRegularFileIsMalformed() throws {
        let message = Message(op: 7, fields: [.init(tag: 1, value: .bytes(Array(repeating: 0x72, count: 70_000)))])
        let frame = try #require(message.encoded(sharing: [0]))
        var template = Array("/tmp/cmux-region-test-XXXXXX".utf8CString)
        let writable = mkstemp(&template)
        try #require(writable >= 0)
        let path = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        defer {
            unlink(path)
            close(writable)
        }
        let payload = message.payload(at: 0)
        let written = payload.withUnsafeBytes { write(writable, $0.baseAddress, $0.count) }
        try #require(written == payload.count)
        let readOnly = open(path, O_RDONLY)
        try #require(readOnly >= 0)
        var fds = [readOnly]
        #expect(Message.decode(frame[...], fds: &fds) == .malformed, "a read-only regular file of the right size")
        #expect(fds.isEmpty, "is taken and closed")
    }

    @Test func sharedCountsOverTheCapTogetherAreMalformed() {
        // Two shared fields of 100 MiB each: each under 128 MiB, together over it.
        let count = UInt64(100 * 1024 * 1024)
        var frame: [UInt8] = []
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { frame += $0 } }
        put(UInt32(2 * (Message.fieldHeaderSize + Message.sharedFieldSize)))
        put(UInt16(7))
        put(UInt16(2))  // two descriptors
        put(UInt32(0))
        for tag: UInt8 in [1, 2] {
            frame += [Message.sharedBytesType, tag]
            put(UInt16(Message.sharedFieldSize))
            put(count)
        }
        var fds: [Int32] = []
        #expect(Message.decode(frame[...], fds: &fds) == .malformed)
        let one = Message(op: 7, fields: [.init(tag: 1, value: .bytes([1]))])
        #expect(one.sharedByteCount([0]) == 1)
    }

    @Test func theInboxPausesAtItsByteLimit() async throws {
        let (aFD, bFD) = try Self.socketPair()
        let a = Recorder(), b = Recorder()
        let sender = a.channel(fd: aFD)
        var options = ChromiumHostControlChannel.Options()
        options.inboxBytesLimit = 100_000
        let receiver = b.channel(fd: bFD, options: options)
        let large = Message(op: 9, fields: [.init(tag: 1, value: .bytes(Array(repeating: 0x61, count: 70_000)))])
        for code in 0..<20 {
            var message = large
            message.fields.append(.init(tag: 2, value: .i32(Int32(code))))
            #expect(sender.send(message))
        }
        await b.wait { b.messages.count == 20 }
        #expect(b.messages.map { $0[2] } == Self.codes(0..<20), "every message arrives, in order")
        #expect(b.largestBatchBytes <= 100_000 + 70_000, "no drain holds more than the limit and one message")
        sender.close()
        receiver.close()
    }

    @Test func sharedPayloadsCountTowardTheQuota() throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        let channel = recorder.channel(fd: fd)
        var code: Int32 = 0
        while channel.stats.pendingMessages == 0, code < 1_000_000 {
            channel.send(Self.key(1, code))
            code += 1
        }
        let before = channel.stats.pendingBytes
        let large = Message(op: 8, fields: [.init(tag: 1, value: .bytes(Array(repeating: 0x71, count: 1 << 20)))])
        #expect(channel.send(large))
        #expect(channel.stats.pendingBytes >= before + (1 << 20), "a waiting region's bytes are counted")
        #expect(channel.stats.quotaExcess > 0, "and put a peer that never reads over quota")
        channel.close()
        close(peer)
    }
}
#endif
