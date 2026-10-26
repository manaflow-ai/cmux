@testable import CmuxNextDaemon
import Darwin
import Dispatch
import Foundation
import Testing

/// The daemon socket writers of the key-carrying connections (control, terminal attach) are on the key
/// echo path: every typed key goes through their drain queue, and the frame that shows the echo waits for
/// it. At the default QoS a busy machine ran them behind utility work. Every other connection stays below
/// user-interactive, so bulk traffic (a loopback forward) never shares a keystroke's class
/// (threading-model.md, QoS table: userInteractive is the main thread and the threads a frame waits for;
/// Chromium gives the threads input and display wait on the same class, base/threading/platform_thread_apple.mm).
@Suite struct SocketWriterQoSTests {
    @Test func theDrainQueueRunsAtTheGivenClass() throws {
        for qos in [DispatchQoS.userInteractive, .utility] {
            var fds: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            defer { fds.forEach { Darwin.close($0) } }

            let writer = SocketWriter(fd: fds[0], label: "com.cmuxterm.next.daemon.write", qos: qos)
            defer { writer.close() }

            #expect(writer.queueQoS == qos)
        }
    }

    @Test func onlyKeyCarryingConnectionsWriteAtUserInteractive() {
        let interactive = DaemonWireStats.Role.allCases.filter { $0.writerQoS == .userInteractive }
        #expect(interactive == [.control, .terminalAttach])
        #expect(DaemonWireStats.Role.loopbackForward.writerQoS == .default)
        #expect(DaemonWireStats.Role.socketProbe.writerQoS == .utility)
        for role in [DaemonWireStats.Role.pageRelay, .agentSessionAttach, .journalRead, .sessionEnding, .shutdown] {
            #expect(role.writerQoS == .userInitiated, "\(role.name)")
        }
    }

    @Test func aWriteStillReachesThePeer() throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { fds.forEach { Darwin.close($0) } }
        // A drain that never delivers must fail this test, not hang the runner: the read gives up after 2 s.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)

        let writer = SocketWriter(fd: fds[0], label: "com.cmuxterm.next.daemon.write",
                                  qos: DaemonWireStats.Role.terminalAttach.writerQoS)
        defer { writer.close() }
        #expect(writer.write(Data("k\n".utf8)) == nil)

        var buffer = [UInt8](repeating: 0, count: 2)
        // A read bounded by SO_RCVTIMEO on the test's own socket: the writer's queue sends the two bytes.
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fds[1], $0.baseAddress, 2) }
        #expect(count == 2, "the writer delivered nothing within 2 s (errno \(errno))")
        #expect(buffer == Array("k\n".utf8))
    }
}
