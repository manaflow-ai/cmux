#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import Darwin
import Testing

/// The main-thread mirror cache (task p01-process-016b): read-your-writes
/// for a post's pending keys until the host's ACK, MIRROR frames applied in
/// order with the events of their batch, and the same rules as
/// ChromiumHost/client/remote_shim_mirror.h
/// (scripts/cmux-next/tests/remote-shim-mirror.test.sh).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ChromiumHostMirrorTests {
    typealias Message = ChromiumHostControlMessage
    typealias Field = ChromiumHostControlMessage.Field

    // Op ids from the generated table (ChromiumHostOp; gen-chromium-host-wire.py).
    static let goBack: UInt16 = 36
    static let tabNavigationState: UInt16 = 65
    static let extList: UInt16 = 68
    static let eventOp: UInt16 = 0x8001
    static let loadStart: Int32 = 8  // CMUX_SHIM_LOAD_START

    static func value(_ text: String) -> [Field] {
        [Field(tag: 0, value: .str(text))]
    }

    /// HostContext::PushMirror's frame for a one-int key.
    static func mirror(_ op: UInt16, browser: Int32, _ text: String) -> Message {
        Message(op: ChromiumHostMirror.mirrorOp,
                fields: [Field(tag: 0, value: .i32(Int32(op))), Field(tag: 0, value: .i32(1)),
                         Field(tag: 0, value: .i32(browser))] + value(text))
    }

    static func ack(_ token: UInt32) -> Message {
        Message(op: ChromiumHostMirror.ackOp, token: token, isReply: true)
    }

    static func event(_ kind: Int32, browser: Int32) -> Message {
        Message(op: eventOp, fields: [Field(tag: 0, value: .i32(kind)), Field(tag: 0, value: .i32(browser))])
    }

    static func navigationState(_ browser: Int32) -> ChromiumHostMirror.PendingKey {
        ChromiumHostMirror.PendingKey(mirror: tabNavigationState, parameters: [.i32(browser)])
    }

    static func socketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    /// One end's deliveries, as a stream the test awaits.
    final class Recorder {
        enum Event: Sendable {
            case messages([Message])
            case end(ChromiumHostControlEnd)
        }

        let events: AsyncStream<Event>
        private let continuation: AsyncStream<Event>.Continuation
        var messages: [Message] = []
        var end: ChromiumHostControlEnd?

        init() {
            let (events, continuation) = AsyncStream<Event>.makeStream()
            self.events = events
            self.continuation = continuation
        }

        func channel(fd: Int32, mirror: ChromiumHostMirror? = nil,
                     onMessage: (@MainActor @Sendable (Message) -> Void)? = nil,
                     onEnd: (@MainActor @Sendable () -> Void)? = nil) -> ChromiumHostControlChannel {
            let continuation = continuation
            return ChromiumHostControlChannel(
                fd: fd, post: { drain in Task { @MainActor in drain() } }, mirror: mirror,
                onMessages: { batch in
                    for message in batch { onMessage?(message) }
                    continuation.yield(.messages(batch))
                },
                onEnd: { reason in
                    onEnd?()
                    continuation.yield(.end(reason))
                })
        }

        func wait(until done: () -> Bool) async {
            if done() { return }
            for await event in events {
                switch event {
                case .messages(let batch): messages += batch
                case .end(let reason): end = reason
                }
                if done() { return }
            }
        }
    }

    /// What the cmux side's event handler read, in event order.
    final class Reads {
        var values: [ChromiumHostMirror.Read] = []
    }

    /// The host's end: answers each post with the given frames under its token.
    final class HostSlot {
        var channel: ChromiumHostControlChannel?
        var answer: (UInt32) -> [Message] = { _ in [] }
    }

    // MARK: The cache

    @Test func aPendingKeyReadsPendingUntilItsAck() {
        let mirror = ChromiumHostMirror()
        #expect(mirror.apply(Self.mirror(Self.tabNavigationState, browser: 7, "old")))
        #expect(mirror.apply(Self.mirror(Self.tabNavigationState, browser: 8, "eight")))
        mirror.markPending(token: 3, [Self.navigationState(7)])
        #expect(mirror.read(Self.tabNavigationState, key: [.i32(7)]) == .pending, "never the old value")
        #expect(mirror.read(Self.tabNavigationState, key: [.i32(8)]) == .value(Self.value("eight")))
        #expect(mirror.apply(Self.mirror(Self.tabNavigationState, browser: 7, "new")))
        #expect(mirror.read(Self.tabNavigationState, key: [.i32(7)]) == .pending, "a push before the ACK may predate the op")
        mirror.markPending(token: 4, [Self.navigationState(7)])
        #expect(mirror.apply(Self.ack(3)))
        #expect(mirror.read(Self.tabNavigationState, key: [.i32(7)]) == .pending, "a newer post still waits")
        #expect(mirror.apply(Self.ack(4)))
        #expect(mirror.read(Self.tabNavigationState, key: [.i32(7)]) == .value(Self.value("new")))
        #expect(mirror.pendingCount == 0)
    }

    @Test func optimisticValuesWildcardsAndDroppedPosts() {
        let mirror = ChromiumHostMirror()
        #expect(mirror.apply(Self.mirror(Self.extList, browser: 3, "[a]")))
        mirror.markPending(token: 5, [.init(mirror: Self.extList, parameters: [nil])])
        #expect(mirror.read(Self.extList, key: [.i32(3)]) == .pending)
        #expect(mirror.read(Self.extList, key: [.i32(4)]) == .pending, "`*` matches a key never pushed too")
        mirror.dropPending(token: 5)
        #expect(mirror.read(Self.extList, key: [.i32(3)]) == .value(Self.value("[a]")), "an unsent post leaves no mark")
        mirror.markPending(token: 6, [.init(mirror: Self.extList, parameters: [.i32(3)], optimistic: Self.value("[]"))])
        #expect(mirror.read(Self.extList, key: [.i32(3)]) == .optimistic(Self.value("[]")))
        #expect(mirror.read(Self.extList, key: [.i32(3)]).fields == Self.value("[]"))
        mirror.markPending(token: 0, [Self.navigationState(1)])
        #expect(mirror.pendingCount == 1, "token 0 has no ACK, so it marks nothing")
        mirror.hostEnded()
        #expect(mirror.read(Self.extList, key: [.i32(3)]) == .absent && mirror.pendingCount == 0)
    }

    @Test func malformedFramesAreRefused() {
        let mirror = ChromiumHostMirror()
        var tooManyKeys = Self.mirror(Self.tabNavigationState, browser: 7, "x")
        tooManyKeys.fields[1] = Field(tag: 0, value: .i32(3))
        #expect(!mirror.apply(tooManyKeys), "a key count past the frame")
        #expect(!mirror.apply(Self.mirror(0, browser: 7, "x")), "op 0 is no export")
        #expect(!mirror.apply(Message(op: ChromiumHostMirror.ackOp, token: 5)), "an ACK is a reply frame")
        #expect(!mirror.apply(Self.ack(0)), "an ACK names a token")
        var answered = Self.mirror(Self.tabNavigationState, browser: 7, "x")
        answered.isReply = true
        #expect(!mirror.apply(answered), "a MIRROR answers no token")
        #expect(mirror.read(Self.tabNavigationState, key: [.i32(7)]) == .absent)
    }

    // MARK: On a socket pair

    @Test func goBackThenNavigationStateInTheSameTurnReadsPending() async throws {
        let (fd, hostFD) = try Self.socketPair()
        let mirror = ChromiumHostMirror()
        let cmux = Recorder(), host = Recorder()
        let reads = Reads()
        let channel = cmux.channel(fd: fd, mirror: mirror) { message in
            guard message.op == Self.eventOp else { return }
            reads.values.append(mirror.read(Self.tabNavigationState, key: [.i32(7)]))
        }
        let slot = HostSlot()
        let peer = host.channel(fd: hostFD) { message in
            guard message.op == Self.goBack else { return }
            for frame in slot.answer(message.token) { slot.channel?.send(frame) }
        }
        slot.channel = peer

        peer.send(Self.mirror(Self.tabNavigationState, browser: 7, "old"))
        peer.send(Self.event(Self.loadStart, browser: 7))
        await cmux.wait { cmux.messages.count == 1 }
        #expect(reads.values == [.value(Self.value("old"))], "the event reads the value pushed before it")
        #expect(!cmux.messages.contains { ChromiumHostMirror.takes($0) }, "MIRROR frames go to the mirror")

        // The host pushes the new state while it dispatches the op, then ACKs it.
        slot.answer = { token in
            [Self.mirror(Self.tabNavigationState, browser: 7, "new"), Self.event(Self.loadStart, browser: 7),
             Self.ack(token), Self.event(Self.loadStart, browser: 7)]
        }
        let goBack = Message(op: Self.goBack, fields: [Field(tag: 0, value: .i32(7))])
        #expect(channel.post(goBack, changing: [Self.navigationState(7)]))
        #expect(mirror.read(Self.tabNavigationState, key: [.i32(7)]) == .pending,
                "go_back then tab_navigation_state in the same turn: pending, never the old value")
        await cmux.wait { cmux.messages.count == 3 }
        #expect(reads.values.dropFirst() == [.pending, .value(Self.value("new"))],
                "an event before the ACK reads pending; the one after it reads the host's value")
        #expect(mirror.pendingCount == 0)

        let ended = Reads()
        let closedFD = try Self.closedPeerFD()
        let closing = cmux.channel(fd: closedFD, mirror: mirror, onEnd: {
            ended.values.append(mirror.read(Self.tabNavigationState, key: [.i32(7)]))
        })
        await cmux.wait { cmux.end != nil }
        #expect(ended.values == [.absent], "the mirror is empty before onEnd runs")
        closing.close()
        channel.close()
        peer.close()
    }

    @Test func anAckOfNoPostIsMalformed() async throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        let channel = recorder.channel(fd: fd, mirror: ChromiumHostMirror())
        let bytes = try #require(Self.ack(77).encoded())
        let written = write(peer, bytes, bytes.count)
        #expect(written == bytes.count)
        await recorder.wait { recorder.end != nil }
        #expect(recorder.end == .malformed)
        channel.close()
        close(peer)
    }

    @Test func aMalformedMirrorEndsTheConnectionBeforeLaterEvents() async throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        let channel = recorder.channel(fd: fd, mirror: ChromiumHostMirror())
        var bad = Self.mirror(Self.tabNavigationState, browser: 7, "x")
        bad.fields[1] = Field(tag: 0, value: .i32(9))
        let bytes = try #require(bad.encoded()) + #require(Self.event(Self.loadStart, browser: 7).encoded())
        let written = write(peer, bytes, bytes.count)
        #expect(written == bytes.count)
        await recorder.wait { recorder.end != nil }
        #expect(recorder.end == .malformed)
        #expect(recorder.messages.isEmpty, "the event after the bad frame never runs")
        channel.close()
        close(peer)
    }

    @Test func aChannelWithoutAMirrorRefusesAPostWithPendingKeys() throws {
        let (fd, peer) = try Self.socketPair()
        let channel = Recorder().channel(fd: fd)
        #expect(!channel.post(Message(op: Self.goBack), changing: [Self.navigationState(7)]))
        channel.close()
        close(peer)
    }

    /// A socket whose peer is already closed: its channel ends at once.
    static func closedPeerFD() throws -> Int32 {
        let (fd, peer) = try socketPair()
        close(peer)
        return fd
    }
}
#endif
