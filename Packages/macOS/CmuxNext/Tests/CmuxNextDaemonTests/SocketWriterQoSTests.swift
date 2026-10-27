@testable import CmuxNextDaemon
import Darwin
import Dispatch
import Foundation
import Testing

/// The daemon socket writer of the key-carrying connection (terminal attach) is on the key echo path: most
/// typed keys (`TerminalAttachment.enqueueInput`) go through its drain queue, and the frame that shows the
/// echo waits for it. Every other connection, the control link included (commands, replies, automation and
/// sidebar events; p04-input-059), stays below user-interactive, so its traffic never shares a keystroke's
/// class. Two key paths still use the control link and so run at user-initiated: pre-attach input of a new
/// split (`send {terminal_id}` from `CreatingTerminalInput`, until p04-input-058) and a TUI's Command chords
/// (`send-key` from `TerminalHooks`). (threading-model.md, QoS table: userInteractive is the main thread and
/// the threads a frame waits for; Chromium gives the threads input and display wait on the same class and
/// its default thread type user-initiated, base/threading/platform_thread_apple.mm.)
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

    @Test func onlyTheKeyCarryingConnectionWritesAtUserInteractive() {
        let interactive = DaemonWireStats.Role.allCases.filter { $0.writerQoS == .userInteractive }
        #expect(interactive == [.terminalAttach])
        #expect(DaemonWireStats.Role.loopbackForward.writerQoS == .default)
        #expect(DaemonWireStats.Role.socketProbe.writerQoS == .utility)
        for role in [DaemonWireStats.Role.control, .pageRelay, .agentSessionAttach, .journalRead, .sessionEnding, .shutdown] {
            #expect(role.writerQoS == .userInitiated, "\(role.name)")
        }
    }

    /// A connection's reader thread runs at its writer's class: both directions serve the same waiter.
    @Test func eachReaderRunsAtItsWritersClass() {
        let expected: [DaemonWireStats.Role: QualityOfService] = [
            .control: .userInitiated, .pageRelay: .userInitiated, .terminalAttach: .userInteractive,
            .agentSessionAttach: .userInitiated, .journalRead: .userInitiated, .loopbackForward: .default,
            .sessionEnding: .userInitiated, .shutdown: .userInitiated, .socketProbe: .utility,
        ]
        for role in DaemonWireStats.Role.allCases {
            #expect(role.readerQoS == expected[role], "\(role.name)")
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

    /// A terminal attach's writer drains on its view's input queue (p04-input-058): while that queue runs
    /// nothing, nothing reaches the socket; once it runs, the bytes do. So a key written from the input queue
    /// goes to `write(2)` on that serial queue, not after a second hop to a writer queue of its own.
    @Test func aWriterWithATargetDrainsOnIt() throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { fds.forEach { Darwin.close($0) } }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)

        // qos-allow: a test queue standing for the attach input queue, which runs at this class
        let target = DispatchQueue(label: "com.cmuxterm.next.test.attach-input", qos: .userInteractive)
        let writer = SocketWriter(fd: fds[0], label: "com.cmuxterm.next.daemon.write",
                                  qos: DaemonWireStats.Role.terminalAttach.writerQoS, target: target)
        defer { writer.close() }
        target.suspend()
        #expect(writer.write(Data("k\n".utf8)) == nil)

        var ready = pollfd(fd: fds[1], events: Int16(POLLIN), revents: 0)
        #expect(poll(&ready, 1, 100) == 0, "the writer sent while its target queue ran nothing")
        target.resume()
        var buffer = [UInt8](repeating: 0, count: 2)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fds[1], $0.baseAddress, 2) }
        #expect(count == 2, "the writer delivered nothing within 2 s of its target running (errno \(errno))")
        #expect(buffer == Array("k\n".utf8))
    }
}
