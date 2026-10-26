#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The input ring to the Chromium Host (p01-process-041): the same golden
/// bytes as ChromiumHost/tests/chromium_host_input_ring_test.cpp
/// (scripts/cmux-next/tests/chromium-host-input-ring.test.sh), the backlog of
/// a full ring, a broken head, the doorbell only for a parked reader, and a
/// reader thread on a real Mach port that takes 1,000,000 frames with none
/// lost and in order. The C++ test runs the same pair across two processes.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ChromiumHostInputRingTests {
    /// The ring's first 16 bytes after format, and the golden key frame in slot 0.
    static let goldenHeader = hexBytes("434d4952010000000010000040000000")
    static let goldenFrame = hexBytes(
        "0500000000000000000000002400000000000000000000000000000000000000"
            + "0000100000000000080706050403020107000000000000000d000d0001000000")

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

    /// Return, page 7: the golden frame once the writer stamps seq 1 and the browser.
    static var goldenKey: ChromiumHostFrame {
        var frame = ChromiumHostFrame(.key, v: [0, 0x24], flags: 0x100000, t0: 0x0102030405060708)
        frame.ch = 0x0d
        frame.unmod = 0x0d
        return frame
    }

    static func key(_ code: Int32) -> ChromiumHostFrame {
        ChromiumHostFrame(.key, v: [0, code], t0: UInt64(code))
    }

    static func move(_ x: Int32) -> ChromiumHostFrame {
        ChromiumHostFrame(.mouse, v: [x, 0, 0, 0, 0, 0])
    }

    /// A ring and this test's own mapping of it (the reader's view).
    final class Fixture {
        let region: ChromiumHostInputRingRegion
        /// The test's mapping, as an address: the deinit reads only Sendable state.
        let address: Int
        let ring: ChromiumHostInputRing

        init(doorbell: (any ChromiumHostInputDoorbell)? = nil) throws {
            region = try ChromiumHostInputRingRegion.make()
            let mapped = mmap(nil, ChromiumHostInputRing.ringBytes, PROT_READ | PROT_WRITE, MAP_SHARED, region.fd, 0)
            let base = try #require(mapped == UnsafeMutableRawPointer(bitPattern: -1) ? nil : mapped)
            address = Int(bitPattern: base)
            ring = try ChromiumHostInputRing(region: region.fd, doorbell: doorbell)
        }

        deinit {
            munmap(UnsafeMutableRawPointer(bitPattern: address), ChromiumHostInputRing.ringBytes)
            close(region.fd)
        }

        var base: UnsafeMutableRawPointer { UnsafeMutableRawPointer(bitPattern: address).unsafelyUnwrapped }

        func word(_ offset: Int) -> AtomicPointerSlot {
            AtomicPointerSlot((base + offset).assumingMemoryBound(to: UInt64.self))
        }

        func bytes(at offset: Int, count: Int) -> [UInt8] {
            Array(UnsafeRawBufferPointer(start: base + offset, count: count))
        }

        /// The seq of the frame at ring position `index`.
        func seq(at index: UInt64) -> UInt32 {
            let slot = ChromiumHostInputRing.framesOffset + Int(index % ChromiumHostInputRing.capacity) * ChromiumHostInputRing.frameSize
            return UInt32(littleEndian: base.loadUnaligned(fromByteOffset: slot + 60, as: UInt32.self))
        }
    }

    /// Counts rings.
    nonisolated final class CountingDoorbell: ChromiumHostInputDoorbell {
        let rings = Atomic<Int>(0)
        func ring() -> Bool {
            rings.add(1, ordering: .relaxed)
            return true
        }
    }

    @Test func layoutAndGoldenFrame() throws {
        #expect(ChromiumHostInputRing.ringBytes == 512 + 4_096 * 64)
        let fixture = try Fixture()
        #expect(fixture.region.arguments == ["--input-doorbell=\(fixture.region.doorbellName)"])
        #expect(fixture.bytes(at: 0, count: 16) == Self.goldenHeader)
        #expect(fixture.ring.write(Self.goldenKey, browser: 7) == .written)
        #expect(fixture.bytes(at: ChromiumHostInputRing.framesOffset, count: 64) == Self.goldenFrame)
        #expect(fixture.word(ChromiumHostInputRing.tailOffset).load(ordering: .acquiring) == 1)
        #expect(ChromiumHostInputRing.browser(of: Self.goldenKey) == 0)
    }

    @Test func refusesWhatIsNotARing() throws {
        var pipeFDs: [Int32] = [-1, -1]
        try #require(pipe(&pipeFDs) == 0)
        defer { pipeFDs.forEach { close($0) } }
        #expect(throws: ChromiumHostInputRingError.notARing) {
            _ = try ChromiumHostInputRing(region: pipeFDs[0], doorbell: nil)
        }
    }

    @Test func refusesAFrameWithAPayload() throws {
        let fixture = try Fixture()
        #expect(fixture.ring.write(ChromiumHostFrame(.navigate, payload: [1]), browser: 1) == .refused)
        #expect(fixture.ring.stats.refused == 1)
        #expect(fixture.word(ChromiumHostInputRing.tailOffset).load(ordering: .acquiring) == 0)
    }

    /// A full ring never waits: frames go to the backlog (moves coalesce, keys
    /// do not) and reach the ring in order once the reader frees slots.
    @Test func fullRingSpillsToTheBacklogInOrder() throws {
        let fixture = try Fixture()
        let ring = fixture.ring
        for code in 1...4_096 { #expect(ring.write(Self.key(Int32(code)), browser: 1) == .written) }
        #expect(ring.write(Self.key(4_097), browser: 1) == .spilled)
        #expect(ring.write(Self.move(1), browser: 1) == .spilled)
        #expect(ring.write(Self.move(2), browser: 1) == .spilled)  // replaces move 1
        #expect(ring.write(Self.move(3), browser: 2) == .spilled)  // another page: kept
        #expect(ring.backlogCount == 3)
        #expect(ring.stats.coalesced == 1)
        #expect(ring.flushBacklog() == .waiting(3))
        // The reader takes two frames.
        fixture.word(ChromiumHostInputRing.headOffset).store(2, ordering: .releasing)
        #expect(ring.write(Self.key(4_098), browser: 1) == .spilled)  // behind the backlog, never ahead
        #expect(ring.backlogCount == 2)
        fixture.word(ChromiumHostInputRing.headOffset).store(4_096, ordering: .releasing)
        #expect(ring.flushBacklog() == .drained)
        #expect(ring.backlogCount == 0)
        // Seqs 4097 (key), 4099 (move 2, which took move 1's place), 4100 (page 2's move), 4101 (key 4098).
        #expect((4_096..<4_100).map { fixture.seq(at: $0) } == [4_097, 4_099, 4_100, 4_101])
        #expect(fixture.word(ChromiumHostInputRing.tailOffset).load(ordering: .acquiring) == 4_100)
    }

    @Test func aHeadNoReaderCanHaveBreaksTheRing() throws {
        let fixture = try Fixture()
        for code in 1...4_096 { fixture.ring.write(Self.key(Int32(code)), browser: 1) }
        fixture.word(ChromiumHostInputRing.headOffset).store(9_999, ordering: .releasing)
        #expect(fixture.ring.write(Self.key(0), browser: 1) == .broken)
        #expect(fixture.ring.isBroken)
        #expect(fixture.ring.write(Self.key(0), browser: 1) == .broken)
    }

    /// One ring per park; none while the reader runs; a park before the
    /// doorbell was looked up rings when it is attached.
    @Test func ringsOnlyAParkedReader() throws {
        let fixture = try Fixture()
        let parked = fixture.word(ChromiumHostInputRing.parkedOffset)
        fixture.ring.write(Self.key(1), browser: 1)
        #expect(fixture.ring.stats.doorbells == 0)
        parked.store(1, ordering: .sequentiallyConsistent)
        fixture.ring.write(Self.key(2), browser: 1)
        #expect(parked.load(ordering: .sequentiallyConsistent) == 0)
        let doorbell = CountingDoorbell()
        fixture.ring.attach(doorbell)
        #expect(doorbell.rings.load(ordering: .relaxed) == 1)
        fixture.ring.write(Self.key(3), browser: 1)
        #expect(doorbell.rings.load(ordering: .relaxed) == 1)
        parked.store(1, ordering: .sequentiallyConsistent)
        fixture.ring.write(Self.key(4), browser: 1)
        fixture.ring.write(Self.key(5), browser: 1)
        #expect(doorbell.rings.load(ordering: .relaxed) == 2)
    }

    /// 1,000,000 frames to a reader thread that parks on a real Mach port
    /// (ChromiumHostMachDoorbell): none lost, every one in order.
    @Test func readerOnAMachDoorbellGetsEveryFrameInOrder() async throws {
        let count: UInt32 = 1_000_000
        let task = mach_task_self_
        var port = mach_port_t(0)
        try #require(mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS)
        defer { mach_port_mod_refs(task, port, MACH_PORT_RIGHT_RECEIVE, -1) }
        try #require(mach_port_insert_right(task, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
        let fixture = try Fixture(doorbell: ChromiumHostMachDoorbell(port: port))
        let (done, finished) = AsyncStream<Bool>.makeStream()
        let address = fixture.address
        let receivePort = port
        Thread {
            finished.yield(Self.read(count, address: address, port: receivePort))
            finished.finish()
        }.start()
        var spills = 0
        for code in 1...count {
            switch fixture.ring.write(Self.key(Int32(bitPattern: code)), browser: 1) {
            case .written: break
            case .spilled:
                spills += 1
                while fixture.ring.flushBacklog() != .drained {}
            case .refused, .broken:
                Issue.record("write \(code) was not taken")
            }
        }
        var results = done.makeAsyncIterator()
        #expect(await results.next() == true)
        print("chromium-host input ring: \(count) frames, \(fixture.ring.stats.doorbells) doorbells, \(spills) spills")
    }

    /// The reader's side of the park protocol (chromium_host_input_ring.h's
    /// Reader), receiving the doorbell with mach_msg. True when it took
    /// `count` frames with seqs 1...count in order.
    nonisolated static func read(_ count: UInt32, address: Int, port: mach_port_t) -> Bool {
        guard let base = UnsafeMutableRawPointer(bitPattern: address) else { return false }
        func word(_ offset: Int) -> AtomicPointerSlot { AtomicPointerSlot((base + offset).assumingMemoryBound(to: UInt64.self)) }
        let tail = word(ChromiumHostInputRing.tailOffset)
        let head = word(ChromiumHostInputRing.headOffset)
        let parked = word(ChromiumHostInputRing.parkedOffset)
        var position: UInt64 = 0
        var expected: UInt32 = 1
        while expected <= count {
            let written = tail.load(ordering: .acquiring)
            while position != written {
                let slot = ChromiumHostInputRing.framesOffset
                    + Int(position & (ChromiumHostInputRing.capacity - 1)) * ChromiumHostInputRing.frameSize
                let seq = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: slot + 60, as: UInt32.self))
                let t0 = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: slot + 40, as: UInt64.self))
                guard seq == expected, t0 == UInt64(expected) else { return false }
                position += 1
                expected += 1
            }
            head.store(position, ordering: .releasing)
            if expected > count { break }
            parked.store(1, ordering: .sequentiallyConsistent)
            if tail.load(ordering: .sequentiallyConsistent) != position {
                parked.store(0, ordering: .relaxed)
                continue
            }
            var message = mach_msg_empty_rcv_t()
            let received = withUnsafeMutablePointer(to: &message) { pointer in
                pointer.withMemoryRebound(to: mach_msg_header_t.self, capacity: 1) { header in
                    mach_msg(header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, mach_msg_size_t(MemoryLayout<mach_msg_empty_rcv_t>.size),
                             port, 10_000, mach_port_name_t(MACH_PORT_NULL))
                }
            }
            guard received == MACH_MSG_SUCCESS else { return false }  // a lost doorbell times out here
            parked.store(0, ordering: .relaxed)
        }
        return true
    }
}
#endif
