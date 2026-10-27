import CmuxNextCompat
import CmuxNextIPC
import Darwin
import Dispatch
import Foundation
import Testing

/// The app's ``FrameWriter`` (plans/cmux-next/chrome-parity/p05-ipc.md, task 055): input before control before
/// bulk before background, call order within a priority, a caller that never waits for the socket, the 64 MiB
/// bound, and descriptors on a message's first byte. Most cases drive a ``GatedSink`` that holds the drain inside
/// chosen sends until the test opens them, so the order on the wire does not depend on timing.
@Suite nonisolated struct FrameWriterTests {
    @Test func anInputFrameEnqueuedAfterEightMiBOfBulkIsWrittenNext() throws {
        // 8 MiB of bulk cut at cmux-ipc's BULK_FRAME_MAX (32 KiB), as the producer cuts it (p05-ipc.md section 3.2):
        // smaller than FrameWriter.batchBytes, so a writer that joined bulk chunks would send several first.
        let chunk = 32 << 10
        let chunks = 256
        #expect(chunk < FrameWriter.batchBytes)
        let input = Data(repeating: 0xEE, count: 100)
        let sink = GatedSink(expectedBytes: chunk * chunks + input.count)
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated)
        defer { writer.close() }

        for _ in 0 ..< chunks {
            #expect(writer.enqueue(Data(repeating: 0xB0, count: chunk), priority: .bulk) == nil)
        }
        try #require(sink.waitUntilSending(), "the drain never started")
        // The drain is held inside the first bulk send; enqueue returns without waiting for it.
        #expect(writer.enqueue(input, priority: .input) == nil)
        #expect(writer.queuedBytes == chunk * (chunks - 1) + input.count)
        sink.open()
        try #require(sink.waitUntilFinished(), "the writer did not deliver every byte")

        let wire = sink.bytes
        #expect(wire.count == chunk * chunks + input.count)
        #expect(wire[0 ..< chunk].allSatisfy { $0 == 0xB0 })
        #expect(wire[chunk ..< chunk + input.count].allSatisfy { $0 == 0xEE }, "the input frame was not next")
        #expect(wire[(chunk + input.count)...].allSatisfy { $0 == 0xB0 })
    }

    @Test func eachBulkChunkIsItsOwnSendSoInputWaitsForOneChunk() throws {
        // Four 16 KiB chunks (the smallest BULK_FRAME_MAX of the 16/32/64 KiB bench) fit in one batchBytes send
        // together; the preemption boundary is still one chunk.
        let chunk = 16 << 10
        let chunks = 4
        #expect(chunk * chunks <= FrameWriter.batchBytes)
        let plug = Data("P".utf8)
        let input = Data(repeating: 0xEE, count: 100)
        let sink = GatedSink(expectedBytes: plug.count + chunk * chunks + input.count, heldSends: [0, 1])
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated)
        defer { writer.close() }

        // Hold the drain in the plug's send, so every bulk chunk waits when the next step is taken.
        #expect(writer.enqueue(plug, priority: .control) == nil)
        try #require(sink.waitUntilSending(), "the drain never started")
        for _ in 0 ..< chunks {
            #expect(writer.enqueue(Data(repeating: 0xB0, count: chunk), priority: .bulk) == nil)
        }
        sink.open()
        // The drain is now held inside the first bulk step; the input frame arrives while it is in flight.
        try #require(sink.waitUntilSending(), "the drain never took a bulk step")
        #expect(writer.enqueue(input, priority: .input) == nil)
        sink.open()
        try #require(sink.waitUntilFinished(), "the writer did not deliver every byte")

        #expect(Array(sink.sendSizes.prefix(3)) == [plug.count, chunk, input.count],
                "a bulk step held more than one chunk")
        let wire = sink.bytes
        #expect(wire.count == plug.count + chunk * chunks + input.count)
        let afterChunk = plug.count + chunk
        #expect(wire[plug.count ..< afterChunk].allSatisfy { $0 == 0xB0 })
        #expect(wire[afterChunk ..< afterChunk + input.count].allSatisfy { $0 == 0xEE },
                "the input frame did not follow the first bulk chunk")
        #expect(wire[(afterChunk + input.count)...].allSatisfy { $0 == 0xB0 })
    }

    @Test func waitingInputAndControlMessagesShareOneSend() throws {
        let plug = Data("P".utf8)
        let sink = GatedSink(expectedBytes: plug.count + 6)
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated)
        defer { writer.close() }

        #expect(writer.enqueue(plug, priority: .bulk) == nil)
        try #require(sink.waitUntilSending(), "the drain never started")
        #expect(writer.enqueue(Data("c1".utf8), priority: .control) == nil)
        #expect(writer.enqueue(Data("i1".utf8), priority: .input) == nil)
        #expect(writer.enqueue(Data("c2".utf8), priority: .control) == nil)
        sink.open()
        try #require(sink.waitUntilFinished(), "the writer did not deliver every byte")

        #expect(sink.sendSizes == [plug.count, 6])
        #expect(String(decoding: sink.bytes, as: UTF8.self) == "Pi1c1c2")
    }

    @Test func priorityOrdersTheQueuesAndCallOrderHoldsWithinOne() throws {
        let plug = Data("P".utf8)
        let messages: [(String, MethodPriority)] = [
            ("c1", .control), ("b1", .bulk), ("c2", .control), ("i1", .input),
            ("g1", .background), ("b2", .bulk), ("i2", .input), ("c3", .control),
        ]
        let expected = "P" + "i1i2" + "c1c2c3" + "b1b2" + "g1"
        let sink = GatedSink(expectedBytes: expected.utf8.count)
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated)
        defer { writer.close() }

        #expect(writer.enqueue(plug, priority: .bulk) == nil)
        try #require(sink.waitUntilSending(), "the drain never started")
        for (text, priority) in messages {
            #expect(writer.enqueue(Data(text.utf8), priority: priority) == nil)
        }
        sink.open()
        try #require(sink.waitUntilFinished(), "the writer did not deliver every byte")

        #expect(String(decoding: sink.bytes, as: UTF8.self) == expected)
    }

    @Test func pastTheLimitEveryPriorityFailsWithBacklog() throws {
        let sink = GatedSink(expectedBytes: 1 + 600)
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated,
                                 limit: 1000)
        defer { writer.close() }
        #expect(FrameWriter.defaultLimit == 64 << 20)

        #expect(writer.enqueue(Data([0x01]), priority: .control) == nil)
        try #require(sink.waitUntilSending(), "the drain never started")
        // The step in flight is not queued: the bound counts what still waits.
        #expect(writer.queuedBytes == 0)
        #expect(writer.enqueue(Data(repeating: 0x02, count: 600), priority: .bulk) == nil)
        #expect(writer.enqueue(Data(repeating: 0x03, count: 600), priority: .bulk) == .backlog(queued: 600))
        #expect(writer.enqueue(Data(repeating: 0x04, count: 600), priority: .input) == .backlog(queued: 600))
        #expect(writer.queuedBytes == 600)
        sink.open()
        try #require(sink.waitUntilFinished(), "the writer did not deliver every byte")
        #expect(sink.bytes.count == 601)
    }

    @Test func closeDropsWhatWaitsAndRefusesLaterMessages() throws {
        let sink = GatedSink(expectedBytes: .max)
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated)

        #expect(writer.enqueue(Data([0x01]), priority: .control) == nil)
        try #require(sink.waitUntilSending(), "the drain never started")
        #expect(writer.enqueue(Data(repeating: 0x02, count: 50), priority: .input) == nil)
        writer.close()
        #expect(writer.queuedBytes == 0)
        #expect(writer.enqueue(Data([0x03]), priority: .input) == .closed)
        sink.open()
    }

    @Test func malformedDescriptorListsAreRefused() throws {
        let sink = GatedSink(expectedBytes: .max)
        let writer = FrameWriter(sink: sink, label: "com.cmuxterm.next.daemon.write", qos: .userInitiated)
        defer {
            writer.close()
            sink.open()
        }
        var descriptors: [Int32] = []
        for _ in 0 ..< 4 {
            var ends: [Int32] = [-1, -1]
            try #require(pipe(&ends) == 0)
            descriptors += ends
        }
        // The writer owns the descriptors it is given, also when it refuses the message: it closes them.
        #expect(writer.enqueue(Data([0x01]), priority: .control, fds: Array(descriptors[0 ..< 5]))
            == .tooManyFds(count: 5))
        #expect(writer.enqueue(Data(), priority: .control, fds: [descriptors[5]]) == .fdsWithoutBytes)
        descriptors[6...].forEach { Darwin.close($0) }
        #expect(writer.enqueue(Data(), priority: .control) == nil)
        #expect(writer.queuedBytes == 0)
    }

    @Test func theDrainQueueRunsAtTheGivenClass() {
        for qos in [DispatchQoS.userInitiated, .utility] {
            let writer = FrameWriter(sink: GatedSink(expectedBytes: .max), label: "com.cmuxterm.next.daemon.write",
                                     qos: qos)
            #expect(writer.queueQoS == qos)
            writer.close()
        }
    }

    @Test func aSocketSinkSendsTheBytesWithTheirDescriptors() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { Darwin.close($0) } }
        // A writer that never delivers must fail this test, not hang the runner: the read gives up after 2 s.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        var pipeEnds: [Int32] = [-1, -1]
        try #require(pipe(&pipeEnds) == 0)
        defer { Darwin.close(pipeEnds[0]) }

        let writer = FrameWriter(sink: SocketFrameSink(fd: pair[0]), label: "com.cmuxterm.next.daemon.write",
                                 qos: .userInitiated)
        defer { writer.close() }
        // The writer owns the pipe's write end from here on and closes its copy once sent.
        #expect(writer.enqueue(Data("frame".utf8), priority: .control, fds: [pipeEnds[1]]) == nil)

        let (bytes, received) = try Self.receive(pair[1], count: 5)
        defer { received.forEach { Darwin.close($0) } }
        #expect(bytes == Array("frame".utf8))
        try #require(received.count == 1)
        // The received descriptor is the pipe's write end: a byte written to it comes out of the read end.
        var byte: UInt8 = 0x2A
        #expect(Darwin.write(received[0], &byte, 1) == 1)
        var echoed: UInt8 = 0
        #expect(Darwin.read(pipeEnds[0], &echoed, 1) == 1)
        #expect(echoed == 0x2A)
    }

    /// One `recvmsg` of `count` bytes and the `SCM_RIGHTS` descriptors that came with them (Darwin's `cmsghdr`
    /// layout, as SocketFrameSink writes it).
    private static func receive(_ fd: Int32, count: Int) throws -> ([UInt8], [Int32]) {
        let headerSpace = (MemoryLayout<cmsghdr>.size + 3) & ~3
        var buffer = [UInt8](repeating: 0, count: count)
        var control = [UInt8](repeating: 0, count: headerSpace + FrameWriter.maxFdsPerMessage * MemoryLayout<Int32>.size)
        var fds: [Int32] = []
        let read = buffer.withUnsafeMutableBytes { bufferBytes in
            control.withUnsafeMutableBytes { controlBytes -> Int in
                var iov = iovec(iov_base: bufferBytes.baseAddress, iov_len: bufferBytes.count)
                return withUnsafeMutablePointer(to: &iov) { iovPointer -> Int in
                    var header = msghdr()
                    header.msg_iov = iovPointer
                    header.msg_iovlen = 1
                    header.msg_control = controlBytes.baseAddress
                    header.msg_controllen = socklen_t(controlBytes.count)
                    // Bounded by SO_RCVTIMEO on the test's own socket.
                    let read = Darwin.recvmsg(fd, &header, 0)
                    guard read >= 0, Int(header.msg_controllen) >= headerSpace else { return read }
                    let cmsg = controlBytes.load(as: cmsghdr.self)
                    guard cmsg.cmsg_level == SOL_SOCKET, cmsg.cmsg_type == SCM_RIGHTS else { return read }
                    for index in 0 ..< (Int(cmsg.cmsg_len) - headerSpace) / MemoryLayout<Int32>.size {
                        fds.append(controlBytes.load(fromByteOffset: headerSpace + index * MemoryLayout<Int32>.size,
                                                     as: Int32.self))
                    }
                    return read
                }
            }
        }
        try #require(read == count, "received \(read) of \(count) bytes within 2 s (errno \(errno))")
        return (buffer, fds)
    }
}

/// A ``FrameSink`` that records every byte and holds the drain inside each send of `heldSends` (by index) until
/// ``open()``; every other send goes straight through.
private nonisolated final class GatedSink: FrameSink {
    private struct Recorded {
        var bytes: [UInt8] = []
        var sendSizes: [Int] = []
    }

    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let expectedBytes: Int
    private let heldSends: Set<Int>
    private let recorded = Mutex(Recorded())

    init(expectedBytes: Int, heldSends: Set<Int> = [0]) {
        self.expectedBytes = expectedBytes
        self.heldSends = heldSends
    }

    func send(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure> {
        let index = recorded.withLock { recorded -> Int in
            defer { recorded.sendSizes.append(bytes.count) }
            return recorded.sendSizes.count
        }
        if heldSends.contains(index) {
            entered.signal()
            // Test only, on the writer's drain queue: a test that never opens the gate fails on its own wait,
            // and this queue moves on after 10 s.
            _ = gate.wait(timeout: .now() + 10)
        }
        let total = recorded.withLock { recorded -> Int in
            recorded.bytes.append(contentsOf: bytes)
            return recorded.bytes.count
        }
        if total == expectedBytes { finished.signal() }
        return .success(bytes.count)
    }

    /// True once the drain is inside the next held send (within 5 s).
    func waitUntilSending() -> Bool { entered.wait(timeout: .now() + 5) == .success }

    /// Lets the held send in progress, or the next one, go through.
    func open() { gate.signal() }

    /// True once the expected byte count arrived (within 10 s).
    func waitUntilFinished() -> Bool { finished.wait(timeout: .now() + 10) == .success }

    var bytes: [UInt8] { recorded.withLock { $0.bytes } }

    /// The byte count of each send, in order.
    var sendSizes: [Int] { recorded.withLock { $0.sendSizes } }
}
