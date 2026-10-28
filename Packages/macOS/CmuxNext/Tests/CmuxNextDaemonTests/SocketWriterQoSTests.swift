@testable import CmuxNextDaemon
import Darwin
import Dispatch
import Foundation
import Testing

/// The daemon socket writer of the key-carrying connection (terminal attach) is on the key echo path: most
/// typed keys (`TerminalAttachment.enqueueInput`) go through its drain queue, and the frame that shows the
/// echo waits for it. Every other connection, the control link included (commands, replies, automation and
/// sidebar events), stays below user-interactive, so its traffic never shares a keystroke's
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

    /// A terminal attach's writer drains on its view's input queue: a write that waits behind
    /// a queued one reaches the socket only once that queue runs, on that serial queue, not after a second hop
    /// to a writer queue of its own. The first write comes from the main thread, which always queues,
    /// so the second, from a worker thread, finds a message waiting and queues behind it.
    @Test func aQueuedWriteDrainsOnTheWritersTarget() async throws {
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
        let first = await MainActor.run { [writer] in writer.write(Data("m\n".utf8)) }
        #expect(first == nil)
        #expect(writer.write(Data("k\n".utf8)) == nil)

        var ready = pollfd(fd: fds[1], events: Int16(POLLIN), revents: 0)
        #expect(poll(&ready, 1, 100) == 0, "the writer sent while its target queue ran nothing")
        #expect(writer.queuedBytes == 4)
        target.resume()
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4)
        while received.count < 4 {
            // A read bounded by SO_RCVTIMEO on the test's own socket.
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fds[1], $0.baseAddress, 4 - received.count) }
            guard count > 0 else { break }
            received += buffer[0 ..< count]
        }
        #expect(received == Array("m\nk\n".utf8), "the writer delivered too little within 2 s of its target running")
        #expect(writer.queueHops == 1)
    }

    /// An idle writer sends a worker thread's write on that thread: the bytes reach the socket
    /// while the target queue runs nothing, and the drain queue is never woken. So a key written from the
    /// attach input queue goes to the socket in that queue's turn.
    @Test func anIdleWriteFromAWorkerThreadNeedsNoTarget() throws {
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
        defer { target.resume() }
        #expect(writer.write(Data("k\n".utf8)) == nil)

        var buffer = [UInt8](repeating: 0, count: 2)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fds[1], $0.baseAddress, 2) }
        #expect(count == 2, "an idle write waited for the suspended target (errno \(errno))")
        #expect(buffer == Array("k\n".utf8))
        #expect(writer.queueHops == 0, "an idle write woke the drain queue")
    }
}
