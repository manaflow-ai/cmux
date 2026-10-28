import CmuxNextCompat
import CmuxNextIPC
import Darwin
import Dispatch
import Foundation
import Testing

/// The inline write fast path of ``FrameWriter`` (plans/cmux-next/chrome-parity/p05-ipc.md, task 140): an idle
/// writer sends a worker thread's message on that thread with no drain-queue hop; what the socket does not take
/// is the next drain step, a tail before everything; a message never passes a waiting one of its own or a higher
/// priority; and a main-thread caller never makes a socket call.
nonisolated extension FrameWriterTests {
    @Test func aThousandIdleInputFramesOnASocketTakeNoQueueHop() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { Darwin.close($0) } }
        // The transport's buffers (LineTransport.socketBufferBytes): 1,000 keys fit while nobody reads.
        for fd in pair {
            for option in [SO_SNDBUF, SO_RCVBUF] {
                var bytes: Int32 = 512 << 10
                try #require(setsockopt(fd, SOL_SOCKET, option, &bytes, socklen_t(MemoryLayout<Int32>.size)) == 0)
            }
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        let sink = SocketFrameSink(fd: pair[0])
        try #require(sink.inlineLimit >= 1024, "the socket refused a send low-water mark")
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInteractive,
                                 isMainThread: { false })
        defer { writer.close() }

        var expected = Data()
        for index in 0 ..< 1000 {
            let frame = Data("INPUT \(index);".utf8)
            expected.append(frame)
            #expect(writer.enqueue(frame, priority: .input) == nil)
        }
        #expect(writer.queueHops == 0, "an idle writer woke its drain queue")

        var received = [UInt8](repeating: 0, count: expected.count)
        var offset = 0
        while offset < received.count {
            let read = received.withUnsafeMutableBytes { buffer in
                Darwin.read(pair[1], buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
            }
            try #require(read > 0, "the socket gave \(offset) of \(received.count) bytes within 2 s")
            offset += read
        }
        #expect(Data(received) == expected)
    }

    @Test func aWorkerThreadsIdleMessagesLeaveInlineInCallOrder() throws {
        let sink = InlineSink(expectedBytes: 6)
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated,
                                 isMainThread: { false })
        defer { writer.close() }

        #expect(writer.enqueue(Data("i1".utf8), priority: .input) == nil)
        #expect(writer.enqueue(Data("c1".utf8), priority: .control) == nil)
        #expect(writer.enqueue(Data("b1".utf8), priority: .bulk) == nil)

        #expect(sink.wire == "i1c1b1")
        #expect(sink.trySendSizes == [2, 2, 2])
        #expect(sink.sendSizes.isEmpty, "an idle message went through the drain queue")
        #expect(writer.queueHops == 0)
    }

    @Test func aMainThreadCallerAlwaysEnqueuesAndNeverSends() async throws {
        let sink = InlineSink(expectedBytes: 4)
        // The system's answer, not an injected one: the messages are enqueued on the main thread.
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated)
        defer { writer.close() }

        let refused = await MainActor.run { [writer] in
            [writer.enqueue(Data("i1".utf8), priority: .input), writer.enqueue(Data("c1".utf8), priority: .control)]
        }
        #expect(refused == [nil, nil])
        try #require(sink.waitUntilFinished(), "the writer did not deliver every byte")

        #expect(sink.trySendSizes.isEmpty, "the main thread wrote inline")
        #expect(sink.sendsOnMainThread == 0, "the main thread called sendmsg")
        #expect(sink.wire == "i1c1")
        #expect(writer.queueHops >= 1)
    }

    @Test func aCallerTheSeamCallsMainAlwaysEnqueues() throws {
        let sink = InlineSink(expectedBytes: 2)
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated,
                                 isMainThread: { true })
        defer { writer.close() }

        #expect(writer.enqueue(Data("i1".utf8), priority: .input) == nil)
        try #require(sink.waitUntilFinished(), "the writer did not deliver every byte")
        #expect(sink.trySendSizes.isEmpty)
        #expect(sink.sendSizes == [2])
        #expect(writer.queueHops == 1)
    }

    @Test func aHalfSentMessagesTailLeavesBeforeAHigherPriorityMessage() throws {
        // The socket takes 2 of the control message's 6 bytes; the drain is held inside the tail's send.
        let sink = InlineSink(expectedBytes: 8, trySendTakes: [2], heldSends: [0])
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated,
                                 isMainThread: { false })
        defer { writer.close() }

        #expect(writer.enqueue(Data("abcdef".utf8), priority: .control) == nil)
        #expect(writer.queueHops == 1, "the tail did not wake the drain")
        try #require(sink.waitUntilSending(), "the drain never sent the tail")
        // A step is in flight: the input frame queues instead of writing inline.
        #expect(writer.enqueue(Data("i1".utf8), priority: .input) == nil)
        #expect(writer.queuedBytes == 2)
        sink.open()
        try #require(sink.waitUntilFinished(), "the writer did not deliver every byte")

        #expect(sink.wire == "abcdefi1")
        #expect(sink.trySendSizes == [6])
        #expect(sink.sendSizes == [4, 2])
    }

    @Test func aMessageNeverPassesAWaitingOneOfItsOwnOrAHigherPriority() throws {
        // A suspended target holds the drain, so queued messages wait while no step is in flight. The socket
        // has no room for the first control message (it takes 0 bytes), then room for everything.
        let target = DispatchQueue(label: "test.frame-writer.inline")
        target.suspend()
        let sink = InlineSink(expectedBytes: 8, trySendTakes: [0])
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated, target: target,
                                 isMainThread: { false })
        defer { writer.close() }

        #expect(writer.enqueue(Data("c1".utf8), priority: .control) == nil)
        // Input passes the waiting control message inline; control and bulk wait behind it.
        #expect(writer.enqueue(Data("i1".utf8), priority: .input) == nil)
        #expect(writer.enqueue(Data("c2".utf8), priority: .control) == nil)
        #expect(writer.enqueue(Data("b1".utf8), priority: .bulk) == nil)
        #expect(sink.wire == "i1")
        #expect(sink.trySendSizes == [2, 2], "a message tried to pass a waiting one of its own or a higher priority")
        target.resume()
        try #require(sink.waitUntilFinished(), "the writer did not deliver every byte")

        #expect(sink.wire == "i1c1c2b1")
        #expect(writer.queueHops == 1)
    }

    @Test func descriptorsOfAMessageTheSocketTookNoneOfRideItsQueuedFirstByte() throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        defer { Darwin.close(ends[0]) }
        let sink = InlineSink(expectedBytes: 5, trySendTakes: [0])
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated,
                                 isMainThread: { false })
        defer { writer.close() }

        // The writer owns the pipe's write end and closes it once sent.
        #expect(writer.enqueue(Data("frame".utf8), priority: .control, fds: [ends[1]]) == nil)
        try #require(sink.waitUntilFinished(), "the writer did not deliver every byte")
        #expect(sink.trySendFds == [1])
        #expect(sink.sendFds == [1], "the descriptors did not ride the queued message's first byte")
    }

    /// A message's descriptors cost the socket room too (`SCM_RIGHTS` control data, which XNU's `sosend` takes
    /// out of the room before the bytes): a message at the low-water mark with a descriptor never goes inline,
    /// where `sendmsg` would send part of it and wait for room for the rest under the writer's lock.
    @Test func aMessageAtTheLimitWithADescriptorNeverGoesInline() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { Darwin.close($0) } }
        for fd in pair {
            for option in [SO_SNDBUF, SO_RCVBUF] {
                var bytes: Int32 = 512 << 10
                try #require(setsockopt(fd, SOL_SOCKET, option, &bytes, socklen_t(MemoryLayout<Int32>.size)) == 0)
            }
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        let sink = SocketFrameSink(fd: pair[0])
        let limit = sink.inlineLimit
        try #require(limit >= 1024, "the socket refused a send low-water mark")
        let control = SocketFrameSink.controlSpace(fdCount: 1)
        #expect(control > MemoryLayout<Int32>.size)
        #expect(sink.takesInline(byteCount: limit, fdCount: 0))
        #expect(!sink.takesInline(byteCount: limit, fdCount: 1))
        #expect(!sink.takesInline(byteCount: limit - control + 1, fdCount: 1))
        #expect(sink.takesInline(byteCount: limit - control, fdCount: 1))

        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        defer { Darwin.close(ends[0]) }
        let message = Data(repeating: 0x61, count: limit)
        // The sink itself refuses it: nothing leaves, so nothing can wait.
        let tried = message.withUnsafeBytes { sink.trySend($0, fds: [ends[1]]) }
        #expect(tried == .success(0))
        var ready = pollfd(fd: pair[1], events: Int16(POLLIN), revents: 0)
        #expect(poll(&ready, 1, 0) == 0, "trySend sent part of a message whose descriptors did not fit")

        // The writer queues it for its drain queue, which sends it whole with its descriptor.
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated,
                                 isMainThread: { false })
        defer { writer.close() }
        // The writer owns the pipe's write end from here and closes it once sent.
        #expect(writer.enqueue(message, priority: .control, fds: [ends[1]]) == nil)
        #expect(writer.queueHops == 1, "a message at the limit with a descriptor went inline")
        var received = [UInt8](repeating: 0, count: limit)
        var offset = 0
        while offset < received.count {
            let read = received.withUnsafeMutableBytes { buffer in
                Darwin.read(pair[1], buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
            }
            try #require(read > 0, "the socket gave \(offset) of \(received.count) bytes within 2 s")
            offset += read
        }
        #expect(Data(received) == message)
    }
}

/// A ``FrameSink`` with an inline path: ``trySend(_:fds:)`` takes the byte count `trySendTakes` lists for its
/// call (in order; all bytes once the list runs out), and ``send(_:fds:)`` holds the drain inside each send of
/// `heldSends` until ``open()``. It records the wire, each call's size and descriptor count, and the blocking
/// sends made on the main thread.
private nonisolated final class InlineSink: FrameSink {
    private struct Recorded {
        var bytes: [UInt8] = []
        var trySendSizes: [Int] = []
        var trySendFds: [Int] = []
        var sendSizes: [Int] = []
        var sendFds: [Int] = []
        var sendsOnMainThread = 0
    }

    let inlineLimit = 64 << 10
    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let expectedBytes: Int
    private let trySendTakes: [Int]
    private let heldSends: Set<Int>
    private let recorded = Mutex(Recorded())

    init(expectedBytes: Int, trySendTakes: [Int] = [], heldSends: Set<Int> = []) {
        self.expectedBytes = expectedBytes
        self.trySendTakes = trySendTakes
        self.heldSends = heldSends
    }

    func trySend(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure> {
        let take = recorded.withLock { recorded -> Int in
            let call = recorded.trySendSizes.count
            recorded.trySendSizes.append(bytes.count)
            recorded.trySendFds.append(fds.count)
            return call < trySendTakes.count ? min(trySendTakes[call], bytes.count) : bytes.count
        }
        record(UnsafeRawBufferPointer(rebasing: bytes.prefix(take)))
        return .success(take)
    }

    func send(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure> {
        let index = recorded.withLock { recorded -> Int in
            defer {
                recorded.sendSizes.append(bytes.count)
                recorded.sendFds.append(fds.count)
                if pthread_main_np() != 0 { recorded.sendsOnMainThread += 1 }
            }
            return recorded.sendSizes.count
        }
        if heldSends.contains(index) {
            entered.signal()
            // Test only, on the writer's drain queue: a test that never opens the gate fails on its own wait,
            // and this queue moves on after 10 s.
            _ = gate.wait(timeout: .now() + 10)
        }
        record(bytes)
        return .success(bytes.count)
    }

    private func record(_ bytes: UnsafeRawBufferPointer) {
        let total = recorded.withLock { recorded -> Int in
            recorded.bytes.append(contentsOf: bytes)
            return recorded.bytes.count
        }
        if total == expectedBytes { finished.signal() }
    }

    /// True once the drain is inside the next held send (within 5 s).
    func waitUntilSending() -> Bool { entered.wait(timeout: .now() + 5) == .success }

    /// Lets the held send in progress, or the next one, go through.
    func open() { gate.signal() }

    /// True once the expected byte count arrived (within 10 s).
    func waitUntilFinished() -> Bool { finished.wait(timeout: .now() + 10) == .success }

    var wire: String { String(decoding: recorded.withLock { $0.bytes }, as: UTF8.self) }
    var trySendSizes: [Int] { recorded.withLock { $0.trySendSizes } }
    var trySendFds: [Int] { recorded.withLock { $0.trySendFds } }
    var sendSizes: [Int] { recorded.withLock { $0.sendSizes } }
    var sendFds: [Int] { recorded.withLock { $0.sendFds } }
    var sendsOnMainThread: Int { recorded.withLock { $0.sendsOnMainThread } }
}
