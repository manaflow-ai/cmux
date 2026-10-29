#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import Darwin
import Testing

/// The main-thread mirror cache: read-your-writes
/// for an op's generated pending keys until the host's ACK, MIRROR frames
/// applied in order with the events of their batch in one `onMessages` call,
/// one mirror per connection, and the same rules as
/// ChromiumHost/client/remote_shim_mirror.h
/// (scripts/cmux-next/tests/remote-shim-mirror.test.sh).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ChromiumHostMirrorTests {
    typealias Message = ChromiumHostControlMessage
    typealias Field = ChromiumHostControlMessage.Field

    static let loadStart = ChromiumHostEventKind.loadStart.rawValue
    static let progress = ChromiumHostEventKind.progress.rawValue  // refreshes no mirror

    static func i32(_ number: Int32) -> Field {
        Field(tag: 0, value: .i32(number))
    }

    static func value(_ text: String) -> [Field] {
        [Field(tag: 0, value: .str(text))]
    }

    /// An `EncodeFields` body (chromium_host_tlv.h): a frame without its header.
    static func body(_ fields: [Field]) -> [UInt8] {
        Array((Message(op: 0, fields: fields).encoded() ?? []).dropFirst(Message.headerSize))
    }

    /// HostContext::PushMirror's frame: the mirror op, then its key and value each as an
    /// `EncodeFields` body in a bytes field.
    static func push(_ op: ChromiumHostOp, key: [Field], _ value: [Field]) -> Message {
        Message(op: ChromiumHostOp.mirrorOp, fields: [i32(Int32(op.rawValue)), Field(tag: 0, value: .bytes(body(key))),
                                                      Field(tag: 0, value: .bytes(body(value)))])
    }

    /// HostContext::PushMirror's frame for a one-int key.
    static func mirror(_ op: ChromiumHostOp, browser: Int32, _ text: String) -> Message {
        push(op, key: [i32(browser)], value(text))
    }

    /// HostContext::ForgetMirror's frame: no value.
    static func forget(_ op: ChromiumHostOp, browser: Int32) -> Message {
        Message(op: ChromiumHostOp.mirrorOp,
                fields: [i32(Int32(op.rawValue)), Field(tag: 0, value: .bytes(body([i32(browser)])))])
    }

    static func ack(_ token: UInt32) -> Message {
        Message(op: ChromiumHostOp.ackOp, token: token, isReply: true)
    }

    static func event(_ kind: Int32, browser: Int32) -> Message {
        Message(op: ChromiumHostOp.eventOp, fields: [i32(kind), i32(browser)])
    }

    /// cmux_shim_go_back(browser) as the client encodes it.
    static func goBack(_ browser: Int32) -> Message {
        Message(op: ChromiumHostOp.goBack.rawValue, fields: [i32(browser)])
    }

    static func navigationState(_ browser: Int32) -> ChromiumHostMirror.PendingKey {
        ChromiumHostMirror.PendingKey(mirror: .tabNavigationState, parameters: [i32(browser)])
    }

    static func state(_ mirror: ChromiumHostMirror, _ browser: Int32) -> ChromiumHostMirror.Read {
        mirror.read(.tabNavigationState, key: [i32(browser)])
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
        /// onMessages calls.
        var batches = 0
        var end: ChromiumHostControlEnd?

        init() {
            let (events, continuation) = AsyncStream<Event>.makeStream()
            self.events = events
            self.continuation = continuation
        }

        /// `onMessage` runs for each message while the batch is iterated, as a router's handler does.
        func channel(fd: Int32,
                     onMessage: (@MainActor @Sendable (Message) -> Void)? = nil,
                     onEnd: (@MainActor @Sendable () -> Void)? = nil) -> ChromiumHostControlChannel {
            let continuation = continuation
            return ChromiumHostControlChannel(
                fd: fd, post: { drain in Task { @MainActor in drain() } },
                onMessages: { batch in
                    var messages: [Message] = []
                    for message in batch {
                        onMessage?(message)
                        messages.append(message)
                    }
                    continuation.yield(.messages(messages))
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
                case .messages(let batch):
                    batches += 1
                    messages += batch
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

    /// The host's end: answers each go_back with the given frames under its token.
    final class HostSlot {
        var channel: ChromiumHostControlChannel?
        var answer: (UInt32) -> [Message] = { _ in [] }
    }

    // MARK: The cache

    @Test func aPendingKeyReadsPendingUntilItsAck() {
        let mirror = ChromiumHostMirror()
        #expect(mirror.apply(Self.mirror(.tabNavigationState, browser: 7, "old")))
        #expect(mirror.apply(Self.mirror(.tabNavigationState, browser: 8, "eight")))
        mirror.markPending(token: 3, [Self.navigationState(7)])
        #expect(Self.state(mirror, 7) == .pending, "never the old value")
        #expect(Self.state(mirror, 8) == .value(Self.value("eight")))
        #expect(mirror.apply(Self.mirror(.tabNavigationState, browser: 7, "new")))
        #expect(Self.state(mirror, 7) == .pending, "a push before the ACK may predate the op")
        mirror.markPending(token: 4, [Self.navigationState(7)])
        #expect(mirror.apply(Self.ack(3)))
        #expect(Self.state(mirror, 7) == .pending, "a newer post still waits")
        #expect(mirror.apply(Self.ack(4)))
        #expect(Self.state(mirror, 7) == .value(Self.value("new")))
        #expect(mirror.pendingCount == 0)
    }

    @Test func optimisticValuesWildcardsAndDroppedPosts() {
        let mirror = ChromiumHostMirror()
        #expect(mirror.apply(Self.mirror(.extList, browser: 3, "[a]")))
        mirror.markPending(token: 5, [.init(mirror: .extList, parameters: [nil])])
        #expect(mirror.read(.extList, key: [Self.i32(3)]) == .pending)
        #expect(mirror.read(.extList, key: [Self.i32(4)]) == .pending, "`*` matches a key never pushed too")
        mirror.dropPending(token: 5)
        #expect(mirror.read(.extList, key: [Self.i32(3)]) == .value(Self.value("[a]")), "an unsent post leaves no mark")
        mirror.markPending(token: 6, [.init(mirror: .extList, parameters: [Self.i32(3)], optimistic: Self.value("[]"))])
        #expect(mirror.read(.extList, key: [Self.i32(3)]) == .optimistic(Self.value("[]")))
        #expect(mirror.read(.extList, key: [Self.i32(3)]).fields == Self.value("[]"))
        mirror.markPending(token: 0, [Self.navigationState(1)])
        #expect(mirror.pendingCount == 1, "token 0 has no ACK, so it marks nothing")
        mirror.hostEnded()
        #expect(mirror.read(.extList, key: [Self.i32(3)]) == .absent && mirror.pendingCount == 0)
    }

    @Test func aKeyIsItsFieldsTagsIncluded() {
        let mirror = ChromiumHostMirror()
        let null = Field(tag: 1, value: .str(""))  // TlvWriter::Str(NULL)
        let empty = Field(tag: 0, value: .str(""))
        #expect(mirror.apply(Self.push(.prefGet, key: [null], Self.value("x"))))
        #expect(mirror.read(.prefGet, key: [null]) == .value(Self.value("x")))
        #expect(mirror.read(.prefGet, key: [empty]) == .absent,
                "NULL is not \"\", as remote_shim_mirror.h keys by EncodeFields")
    }

    @Test func aMirrorWithNoValueForgetsTheKey() {
        let mirror = ChromiumHostMirror()
        #expect(mirror.apply(Self.mirror(.tabNavigationState, browser: 7, "seven")))
        #expect(mirror.apply(Self.mirror(.tabNavigationState, browser: 8, "eight")))
        #expect(mirror.apply(Self.forget(.tabNavigationState, browser: 7)),
                "BEFORE_CLOSE's keys, or a value over the frame")
        #expect(Self.state(mirror, 7) == .absent)
        #expect(Self.state(mirror, 8) == .value(Self.value("eight")))
    }

    @Test func malformedFramesAreRefused() {
        let mirror = ChromiumHostMirror()
        var cutKey = Self.mirror(.tabNavigationState, browser: 7, "x")
        cutKey.fields[1] = Field(tag: 0, value: .bytes(Array(Self.body([Self.i32(7)]).dropLast())))
        #expect(!mirror.apply(cutKey), "a key body that ends inside a field")
        var intKey = Self.mirror(.tabNavigationState, browser: 7, "x")
        intKey.fields[1] = Self.i32(7)
        #expect(!mirror.apply(intKey), "a key that is not an EncodeFields body")
        var extra = Self.mirror(.tabNavigationState, browser: 7, "x")
        extra.fields.append(Self.i32(1))
        #expect(!mirror.apply(extra), "a field after the value")
        var noExport = Self.mirror(.tabNavigationState, browser: 7, "x")
        noExport.fields[0] = Self.i32(0)
        #expect(!mirror.apply(noExport), "op 0 is no export")
        #expect(!mirror.apply(Message(op: ChromiumHostOp.ackOp, token: 5)), "an ACK is a reply frame")
        #expect(!mirror.apply(Self.ack(0)), "an ACK names a token")
        var answered = Self.mirror(.tabNavigationState, browser: 7, "x")
        answered.isReply = true
        #expect(!mirror.apply(answered), "a MIRROR answers no token")
        #expect(Self.state(mirror, 7) == .absent)
    }

    // MARK: The generated pending keys

    @Test func anOpsPendingKeysComeFromTheGeneratedTable() {
        typealias Key = ChromiumHostMirror.PendingKey
        #expect(Key.changed(by: Self.goBack(7)) == [
            Key(mirror: .tabNavigationEntries, parameters: [Self.i32(7)]),
            Key(mirror: .tabNavigationState, parameters: [Self.i32(7)]),
        ], "go_back: tab.navigation_entries[browser_id], tab.navigation_state[browser_id]")
        let setEnabled = Message(op: ChromiumHostOp.extSetEnabled.rawValue,
                                 fields: [Self.i32(3), Field(tag: 0, value: .str("ext")), Self.i32(0)])
        #expect(Key.changed(by: setEnabled) == [
            Key(mirror: .extList, parameters: [nil]), Key(mirror: .extActions, parameters: [nil, nil]),
            Key(mirror: .extCommands, parameters: [nil]), Key(mirror: .omniboxKeywords, parameters: [nil]),
        ], "ext_set_enabled marks every tab's extension mirrors")
        #expect(Key.changed(by: Message(op: ChromiumHostOp.closeAll.rawValue)) == [
            Key(mirror: .liveBrowserCount, parameters: []), Key(mirror: .windowCount, parameters: []),
        ])
        #expect(Key.changed(by: Message(op: ChromiumHostOp.goBack.rawValue)) == nil, "the frame lacks browser_id")
        #expect(Key.changed(by: Message(op: ChromiumHostOp.reload.rawValue, fields: [Self.i32(7)])) == [])
        #expect(Key.marks(Self.goBack(7)) && !Key.marks(Message(op: ChromiumHostOp.reload.rawValue)))
        #expect(!Key.marks(Message(op: ChromiumHostOp.goBack.rawValue, token: 1, isReply: true)), "a reply marks nothing")
    }

    @Test func onlyPostSendsAnOpWithPendingKeys() async throws {
        let (fd, peer) = try Self.socketPair()
        let channel = Recorder().channel(fd: fd)
        #expect(!channel.send(Self.goBack(7)), "send would leave the keys unmarked")
        await #expect(throws: ChromiumHostControlError.changesMirror) { try await channel.request(Self.goBack(7)) }
        #expect(!channel.post(Message(op: ChromiumHostOp.reload.rawValue, fields: [Self.i32(7)])),
                "an op without pending keys goes through send")
        #expect(!channel.post(Message(op: ChromiumHostOp.goBack.rawValue)), "a frame without browser_id")
        #expect(channel.mirror.pendingCount == 0)
        #expect(channel.post(Self.goBack(7)))
        #expect(Self.state(channel.mirror, 7) == .pending)
        channel.close()
        close(peer)
    }

    // MARK: On a socket pair

    @Test func goBackThenNavigationStateInTheSameTurnReadsPending() async throws {
        let (fd, hostFD) = try Self.socketPair()
        let cmux = Recorder(), host = Recorder()
        let reads = Reads()
        let mirrorSlot = HostSlot()
        let channel = cmux.channel(fd: fd) { message in
            guard message.op == ChromiumHostOp.eventOp, let mirror = mirrorSlot.channel?.mirror else { return }
            reads.values.append(Self.state(mirror, 7))
        }
        mirrorSlot.channel = channel
        let slot = HostSlot()
        let peer = host.channel(fd: hostFD) { message in
            guard message.op == ChromiumHostOp.goBack.rawValue else { return }
            for frame in slot.answer(message.token) { slot.channel?.send(frame) }
        }
        slot.channel = peer

        peer.send(Self.mirror(.tabNavigationState, browser: 7, "old"))
        peer.send(Self.event(Self.loadStart, browser: 7))
        await cmux.wait { cmux.messages.count == 1 }
        #expect(reads.values == [.value(Self.value("old"))], "the event reads the value pushed before it")
        #expect(!cmux.messages.contains { ChromiumHostMirror.takes($0) }, "MIRROR frames go to the mirror")

        // As host_dispatch.inc's go_back case: an event already queued, then the call, the refresh of
        // its pending keys (RefreshMirror: Chrome's state with the pending entry) and the ACK; another
        // event. The navigation commits frames later and pushes again before its LOAD_START.
        slot.answer = { token in
            [Self.event(Self.progress, browser: 8), Self.mirror(.tabNavigationState, browser: 7, "back pending"),
             Self.ack(token), Self.event(Self.progress, browser: 8)]
        }
        #expect(channel.post(Self.goBack(7)))
        #expect(Self.state(channel.mirror, 7) == .pending,
                "go_back then tab_navigation_state in the same turn: pending, never the old value")
        await cmux.wait { cmux.messages.count == 3 }
        #expect(reads.values.dropFirst() == [.pending, .value(Self.value("back pending"))],
                "pending until the ACK; between the ACK and the commit, the host's value after the op")
        #expect(channel.mirror.pendingCount == 0)
        peer.send(Self.mirror(.tabNavigationState, browser: 7, "committed"))
        peer.send(Self.event(Self.loadStart, browser: 7))
        await cmux.wait { cmux.messages.count == 4 }
        #expect(reads.values.last == .value(Self.value("committed")))
        channel.close()
        peer.close()
    }

    @Test func aDrainIsOneOnMessagesCall() async throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        let reads = Reads()
        let slot = HostSlot()
        let channel = recorder.channel(fd: fd) { _ in
            if let mirror = slot.channel?.mirror { reads.values.append(Self.state(mirror, 7)) }
        }
        slot.channel = channel
        var bytes: [UInt8] = []
        for frame in [Self.mirror(.tabNavigationState, browser: 7, "one"), Self.event(Self.loadStart, browser: 7),
                      Self.mirror(.tabNavigationState, browser: 7, "two"), Self.event(Self.loadStart, browser: 7)] {
            bytes += try #require(frame.encoded())
        }
        let written = write(peer, bytes, bytes.count)  // one write: one read, one drain
        #expect(written == bytes.count)
        await recorder.wait { recorder.messages.count == 2 }
        #expect(recorder.batches == 1, "MIRROR, EVENT, MIRROR, EVENT is one onMessages call")
        #expect(reads.values == [.value(Self.value("one")), .value(Self.value("two"))],
                "each handler reads the value pushed before its event and none after")
        channel.close()
        close(peer)
    }

    @Test func eachConnectionHasItsOwnMirror() async throws {
        let (fdA, hostA) = try Self.socketPair()
        let (fdB, hostB) = try Self.socketPair()
        let a = Recorder(), b = Recorder()
        let channelA = a.channel(fd: fdA)
        let channelB = b.channel(fd: fdB)
        #expect(channelA.mirror !== channelB.mirror)
        #expect(channelA.post(Self.goBack(7)) && channelB.post(Self.goBack(7)), "both posts take token 1")
        // Host A acks its token 1 and ends; B's mark under its own token 1 stays.
        let ack = try #require(Self.ack(1).encoded())
        #expect(write(hostA, ack, ack.count) == ack.count)
        close(hostA)
        await a.wait { a.end != nil }
        #expect(Self.state(channelA.mirror, 7) == .absent && channelA.mirror.pendingCount == 0)
        #expect(Self.state(channelB.mirror, 7) == .pending, "an old host's ACK and end never reach the new mirror")
        #expect(channelB.mirror.pendingCount == 2)

        // The mirror is empty before onEnd runs.
        let ended = Reads()
        let (fdC, hostC) = try Self.socketPair()
        let slot = HostSlot()
        let c = Recorder()
        let channelC = c.channel(fd: fdC, onEnd: {
            if let mirror = slot.channel?.mirror { ended.values.append(Self.state(mirror, 7)) }
        })
        slot.channel = channelC
        let push = try #require(Self.mirror(.tabNavigationState, browser: 7, "c").encoded())
        #expect(write(hostC, push, push.count) == push.count)
        close(hostC)
        await c.wait { c.end != nil }
        #expect(ended.values == [.absent])
        channelA.close()
        channelB.close()
        channelC.close()
        close(hostB)
    }

    @Test func anAckOfNoPostIsMalformed() async throws {
        let (fd, peer) = try Self.socketPair()
        let recorder = Recorder()
        let channel = recorder.channel(fd: fd)
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
        let channel = recorder.channel(fd: fd)
        var bad = Self.mirror(.tabNavigationState, browser: 7, "x")
        bad.fields[1] = Self.i32(9)  // the key is not an EncodeFields body
        let bytes = try #require(Self.event(Self.progress, browser: 7).encoded()) + #require(bad.encoded())
            + #require(Self.event(Self.loadStart, browser: 7).encoded())
        let written = write(peer, bytes, bytes.count)
        #expect(written == bytes.count)
        await recorder.wait { recorder.end != nil }
        #expect(recorder.end == .malformed)
        #expect(recorder.messages.map { $0.fields.first } == [Self.i32(Self.progress)],
                "the event before the bad frame runs; the one after it never does")
        channel.close()
        close(peer)
    }
}
#endif
