#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import CmuxNextWakeups
import Foundation
import Testing

/// The Wakeups OS seams read the same facts on both kernels (p15-oracle-126): the peer of a unix socket
/// (`LOCAL_PEER*` on Darwin, `SO_PEERCRED` on Linux) and this process's usage (`proc_pid_rusage` and libproc on
/// Darwin, `/proc` on Linux).
@Suite struct PlatformSeamsTests {
    @Test func aSocketPeerIsThisProcessWithItsUserAndExecutable() throws {
        var pair: [Int32] = [-1, -1]
        // SAFETY: socketpair writes two descriptors into `pair`, a local array of two.
        let made = unsafe socketpair(AF_UNIX, streamSocket, 0, &pair)
        try #require(made == 0)
        defer { pair.forEach { close($0) } }
        let peer = try #require(UnixSocketPeer(descriptor: pair[0]))
        #expect(peer.pid == getpid())
        #expect(peer.uid == getuid())
        let me = try #require(ProcessUsage.path(of: getpid()))
        #expect(peer.runs(URL(fileURLWithPath: me)), "the peer runs this test binary")
        #expect(UnixSocketPeer(descriptor: -1) == nil, "no socket, no peer")
    }

    @Test func thisProcessSamplesWithItsParentPathAndGrowingCPU() throws {
        let first = try #require(ProcessUsage.sample(getpid()))
        #expect(first.pid == getpid())
        #expect(first.parent == getppid())
        #expect(!first.path.isEmpty)
        #expect(first.physFootprint > 0)
        var spin: UInt64 = 0
        let until = DispatchTime.now().uptimeNanoseconds + 30_000_000
        while DispatchTime.now().uptimeNanoseconds < until { spin &+= 1 }
        let second = try #require(ProcessUsage.sample(getpid()))
        #expect(second.cpuNanos > first.cpuNanos, "30 ms of spinning (\(spin) turns) shows as CPU time")
        #expect(second.uptimeNanos > first.uptimeNanos)
        #expect(ProcessUsage.interruptWakeups(of: getpid()) != nil)
        #expect(ProcessUsage.arguments(of: getpid()).isEmpty == false)
        #expect(ProcessUsage.sample(-1) == nil)
    }

    #if os(Linux)
    @Test func procStatusGivesTheUserTheVoluntarySwitchesAndThePrivateFootprint() throws {
        let text = "Name:\tcmux\nUid:\t1000\t1001\t1001\t1001\nRssAnon:\t   2048 kB\nVmSwap:\t     16 kB\n"
            + "voluntary_ctxt_switches:\t42\nnonvoluntary_ctxt_switches:\t7\n"
        let status = try #require(LinuxProcStatus(text))
        #expect(status.effectiveUID == 1001)
        #expect(status.voluntarySwitches == 42)
        #expect(status.privateFootprintBytes == (2048 + 16) * 1024)
        #expect(LinuxProcStatus("Name:\tcmux\n") == nil, "no Uid line, no status")
    }

    @Test func procStatCountsFieldsAfterAProcessNameWithSpacesAndParentheses() throws {
        // pid (comm) state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime ...
        let text = "4242 (cmux (helper) x) S 17 4242 4242 0 -1 4194304 10 0 0 0 250 50 0 0 20 0 1 0 100\n"
        let stat = try #require(LinuxProcStat(text, ticksPerSecond: 100))
        #expect(stat.parent == 17)
        #expect(stat.cpuNanos == 3_000_000_000, "300 ticks at 100 Hz")
        #expect(LinuxProcStat("4242 (cmux) S 17", ticksPerSecond: 100) == nil)
    }

    @Test func inotifyRecordsMapToTheVnodeEventsFolderChangesReads() {
        func record(watch: Int32, mask: UInt32, name: String) -> [UInt8] {
            let padded = name.isEmpty ? 0 : (name.utf8.count / 16 + 1) * 16
            var bytes: [UInt8] = []
            for word in [UInt32(bitPattern: watch), mask, 0, UInt32(padded)] {
                bytes += (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } // little-endian, as x86 and arm64
            }
            return bytes + Array(name.utf8) + [UInt8](repeating: 0, count: padded - name.utf8.count)
        }
        let bytes = record(watch: 1, mask: UInt32(IN_CREATE), name: "mine.png")
            + record(watch: 2, mask: UInt32(IN_DELETE_SELF), name: "")
            + record(watch: 2, mask: UInt32(IN_IGNORED), name: "")
            + record(watch: -1, mask: UInt32(IN_Q_OVERFLOW), name: "")
            + record(watch: 3, mask: UInt32(IN_MOVE_SELF), name: "")
        let events = InotifyEvent.parse(bytes[...])
        #expect(events.map(\.watch) == [1, 2, 2, -1, 3])
        #expect(events.map(\.fileSystemEvent) == [.write, .delete, nil, .rename, .rename])
    }
    #endif
}

/// `SOCK_STREAM` as `socketpair` takes it: Glibc imports it as an enum case.
#if canImport(Darwin)
private let streamSocket = SOCK_STREAM
#else
private let streamSocket = Int32(SOCK_STREAM.rawValue)
#endif
