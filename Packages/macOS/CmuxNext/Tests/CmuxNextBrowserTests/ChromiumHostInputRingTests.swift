#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The input ring to the Chromium Host: the same golden
/// bytes as ChromiumHost/tests/chromium_host_input_ring_test.cpp
/// (scripts/cmux-next/tests/chromium-host-input-ring.test.sh), the backlog of
/// a full ring (keys and clicks never dropped, moves folded per page), a
/// broken head, the doorbell only for a parked reader, and a process pair:
/// this writer against the host's own C++ reader (HostInput over
/// MachDoorbell, built from chromium_host_input_ring_reader.cpp) in a child
/// process, 1,000,000 frames with none lost and in order.
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

    static func wheel(deltaY: Double, phase: UInt, momentum: UInt) -> ChromiumHostFrame {
        .wheel(.init(x: 10, y: 20, deltaX: 0, deltaY: deltaY, precise: true, phase: phase, momentumPhase: momentum,
                     modifierFlags: 0, time: 0))
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
        func seq(at index: UInt64) -> UInt32 { field(at: index, offset: 60) }

        /// The kind of the frame at ring position `index`.
        func kind(at index: UInt64) -> UInt32 { field(at: index, offset: 0) }

        /// v0 (x) of the frame at ring position `index`.
        func x(at index: UInt64) -> Int32 { Int32(bitPattern: field(at: index, offset: 8)) }

        /// v[`slot`] of the frame at ring position `index`.
        func v(_ slot: Int, at index: UInt64) -> Int32 { Int32(bitPattern: field(at: index, offset: 8 + 4 * slot)) }

        private func field(at index: UInt64, offset: Int) -> UInt32 {
            let slot = ChromiumHostInputRing.framesOffset + Int(index % ChromiumHostInputRing.capacity) * ChromiumHostInputRing.frameSize
            return UInt32(littleEndian: base.loadUnaligned(fromByteOffset: slot + offset, as: UInt32.self))
        }

        /// Plays the reader until the writer's backlog is empty: reads every
        /// written frame, frees the slots, and lets the writer move more in.
        /// The kinds and seqs read, oldest first.
        func drain() -> [(kind: UInt32, seq: UInt32)] {
            let tail = word(ChromiumHostInputRing.tailOffset)
            let head = word(ChromiumHostInputRing.headOffset)
            var read: [(kind: UInt32, seq: UInt32)] = []
            var position = head.load(ordering: .acquiring)
            repeat {
                let written = tail.load(ordering: .acquiring)
                while position != written {
                    read.append((kind: kind(at: position), seq: seq(at: position)))
                    position += 1
                }
                head.store(position, ordering: .releasing)
            } while ring.flushBacklog() != .drained || position != tail.load(ordering: .acquiring)
            return read
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

    /// Keys are never dropped. Before the fix the backlog refused every frame
    /// over 4,096, keys too, and moves interleaved with keys never folded (only
    /// the last entry was tried): the 4,097th waiting frame, a key, was lost.
    @Test func aFullRingNeverDropsAKey() throws {
        let fixture = try Fixture()
        let ring = fixture.ring
        for code in 1...4_096 { ring.write(Self.key(Int32(code)), browser: 1) }
        let pairs = ChromiumHostInputRing.coalescableLimit + 1_000
        var keySeqs = Array(UInt32(1)...4_096)
        var keysTaken = true
        for index in 0..<pairs {
            let move = ring.write(Self.move(Int32(index)), browser: 1)
            keysTaken = keysTaken && ring.write(Self.key(Int32(index)), browser: 1) == .spilled
            #expect(move == (index < ChromiumHostInputRing.coalescableLimit ? ChromiumHostInputRing.Push.spilled : .dropped))
            keySeqs.append(UInt32(4_096 + 2 * index + 2))
        }
        #expect(keysTaken)
        #expect(ring.stats.dropped == 1_000)
        #expect(ring.backlogCount == pairs + ChromiumHostInputRing.coalescableLimit)
        let read = fixture.drain()
        let keyKind = ChromiumHostFrame.Kind.key.rawValue
        #expect(read.filter { $0.kind == keyKind }.map { $0.seq } == keySeqs)
        #expect(read.count == 4_096 + pairs + ChromiumHostInputRing.coalescableLimit)
        #expect(ring.backlogCount == 0)
    }

    /// A page's moves fold into its newest waiting move even when other
    /// pages' frames came between; a key of the page ends the fold.
    @Test func movesFoldPerPage() throws {
        let fixture = try Fixture()
        let ring = fixture.ring
        for code in 1...4_096 { ring.write(Self.key(Int32(code)), browser: 1) }
        for x in Int32(1)...100 {
            ring.write(Self.move(x), browser: 1)
            ring.write(Self.key(x), browser: 2)
        }
        #expect(ring.backlogCount == 101)  // page 1's one move, page 2's 100 keys
        #expect(ring.stats.coalesced == 99)
        ring.write(Self.key(0), browser: 1)
        #expect(ring.write(Self.move(500), browser: 1) == .spilled)
        #expect(ring.backlogCount == 103)
        let read = fixture.drain()
        #expect(read.count == 4_096 + 103)
        #expect(fixture.x(at: 4_096) == 100)  // the newest position of page 1's folded move
        #expect(fixture.x(at: 4_096 + 102) == 500)
        #expect(ring.stats.dropped == 0)
    }

    /// A page's wheels fold only within one phase and momentum phase,
    /// so a gesture's begin and end and its momentum's start
    /// each reach the host. Before, a waiting wheel took any newer one and
    /// its phases with it.
    @Test func wheelsFoldOnlyWithinAPhase() throws {
        let fixture = try Fixture()
        let ring = fixture.ring
        for code in 1...4_096 { ring.write(Self.key(Int32(code)), browser: 1) }
        let began: UInt = 1, changed: UInt = 4, ended: UInt = 8
        let sent: [(phase: UInt, momentum: UInt)] = [(began, 0), (changed, 0), (changed, 0), (ended, 0), (0, began),
                                                     (0, changed), (0, changed)]
        for (phase, momentum) in sent { ring.write(Self.wheel(deltaY: -2, phase: phase, momentum: momentum), browser: 1) }
        #expect(ring.backlogCount == 5)
        #expect(ring.stats.coalesced == 2)
        _ = fixture.drain()
        let positions = UInt64(4_096)..<4_101
        #expect(positions.map { fixture.v(4, at: $0) } == [1, 4, 8, 0, 0])
        #expect(positions.map { fixture.v(5, at: $0) } == [0, 0, 0, 1, 4])
        #expect(positions.map { fixture.v(3, at: $0) } == [-200, -400, -200, -200, -400])
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

    /// The process pair: this writer against the host's own reader (HostInput
    /// over MachDoorbell, chromium_host_input_ring.h) in a child process that
    /// checks the doorbell in with a queue limit of 1, as the host does.
    /// 1,000,000 keys: none lost, every one in order.
    @Test func theHostsReaderInAChildProcessGetsEveryFrameInOrder() async throws {
        let count: UInt32 = 1_000_000
        let region = try ChromiumHostInputRingRegion.make()
        defer { close(region.fd) }
        let regionFD = region.fd
        let name = region.doorbellName
        let reader = try await Task.detached { try ReaderProcess.start(doorbell: name, frames: count, regionFD: regionFD) }.value
        let ring = try ChromiumHostInputRing(region: regionFD, doorbell: reader.doorbell)
        var spills = 0
        var readerAlive = true
        for code in 1...count where readerAlive {
            switch ring.write(Self.key(Int32(bitPattern: code)), browser: 1) {
            case .written: break
            case .spilled:
                spills += 1
                var tries = 0
                while ring.flushBacklog() != .drained {
                    tries += 1
                    if tries % 4_096 == 0, !ReaderProcess.isRunning(reader.pid) {
                        readerAlive = false
                        break
                    }
                }
            case .refused, .dropped, .broken:
                Issue.record("write \(code) was not taken")
            }
        }
        let pid = reader.pid
        let status = await Task.detached { ReaderProcess.exitStatus(of: pid) }.value
        #expect(readerAlive)
        #expect(status == 0)  // 1: a frame lost or out of order; 4: the reader ended without Stop
        print("chromium-host input ring pair: \(count) frames, \(ring.stats.doorbells) doorbells, \(spills) spills")
    }

    /// Why the reader child could not start.
    nonisolated enum ReaderProcessError: Error {
        case build(Int32)
        case spawn
        case notReady(Int32)
        case noDoorbell
    }

    /// The host's C++ reader in a child process, built here from
    /// ChromiumHost/tests/chromium_host_input_ring_reader.cpp.
    nonisolated struct ReaderProcess: Sendable {
        let pid: pid_t
        let doorbell: ChromiumHostMachDoorbell

        static let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "ChromiumHost/tests/chromium_host_input_ring_reader.cpp")

        /// Builds and starts the reader on the ring in `regionFD`, waits until
        /// it checked the doorbell in, and looks the doorbell up. Blocks: off
        /// the main actor.
        static func start(doorbell name: String, frames: UInt32, regionFD: Int32) throws(ReaderProcessError) -> ReaderProcess {
            let binary = FileManager.default.temporaryDirectory
                .appending(path: "chromium-host-input-ring-reader-\(getpid())-\(UInt32.random(in: .min ... .max))").path
            defer { unlink(binary) }
            guard let compiler = spawn(["/usr/bin/xcrun", "clang++", "-std=c++20", "-O2", "-o", binary, source.path]) else {
                throw .spawn
            }
            let built = exitStatus(of: compiler)
            guard built == 0 else { throw .build(built) }
            var ready: [Int32] = [-1, -1]
            guard pipe(&ready) == 0 else { throw .spawn }
            let child = spawn([binary, name, String(frames)], ringFD: regionFD, stdoutFD: ready[1])
            close(ready[1])
            defer { close(ready[0]) }
            guard let child else { throw .spawn }
            var byte: UInt8 = 0
            var count = read(ready[0], &byte, 1)
            while count < 0 && errno == EINTR { count = read(ready[0], &byte, 1) }
            guard count == 1, byte == UInt8(ascii: "r") else { throw .notReady(exitStatus(of: child)) }
            guard let doorbell = ChromiumHostMachDoorbell.lookUp(name: name) else {
                kill(child, SIGKILL)
                _ = exitStatus(of: child)
                throw .noDoorbell
            }
            return ReaderProcess(pid: child, doorbell: doorbell)
        }

        /// Starts `arguments[0]` with stdin from /dev/null, stderr as this
        /// process's, stdout on `stdoutFD` (else this process's), the ring on
        /// the host's fd 5 when `ringFD` is given, and no other descriptor.
        static func spawn(_ arguments: [String], ringFD: Int32 = -1, stdoutFD: Int32 = -1) -> pid_t? {
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            if stdoutFD >= 0 {
                posix_spawn_file_actions_adddup2(&actions, stdoutFD, 1)
            } else {
                posix_spawn_file_actions_addinherit_np(&actions, 1)
            }
            posix_spawn_file_actions_addinherit_np(&actions, 2)
            if ringFD >= 0 { posix_spawn_file_actions_adddup2(&actions, ringFD, ChromiumHostInputRing.hostDescriptor) }
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
            let argv = arguments.map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            var pid: pid_t = 0
            guard posix_spawn(&pid, arguments[0], &actions, &attributes, argv, environ) == 0 else { return nil }
            return pid
        }

        /// Reaps `pid`: its exit status, or -1 after a signal.
        static func exitStatus(of pid: pid_t) -> Int32 {
            var status: Int32 = 0
            var result = waitpid(pid, &status, 0)
            while result < 0 && errno == EINTR { result = waitpid(pid, &status, 0) }
            guard result == pid, status & 0x7f == 0 else { return -1 }
            return (status >> 8) & 0xff
        }

        /// False once `pid` ended (it stays a zombie until exitStatus reaps it).
        static func isRunning(_ pid: pid_t) -> Bool {
            var info = siginfo_t()
            return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == 0
        }
    }
}
#endif
