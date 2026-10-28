@testable import CmuxNextDaemon
import Darwin
import Dispatch
import Foundation
import Testing

/// The daemon socket writer registers the `daemon.write` lane and sends each drain step inside one scope of
/// 2 s (plans/cmux-next/chrome-parity/p09-observability.md, section E, task 069); a write waiting for the drain
/// queue is in none, and so is an inline send of an idle writer, which never waits for the socket.
/// The drain runs on a target the test holds; the first write comes from the main thread, which always queues,
/// so both writes wait before the first step.
@Suite(.timeLimit(.minutes(1))) struct SocketWriterHangScopeTests {
    @Test func eachDrainStepIsOneScopeAndAQueuedWriteIsNone() async throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { fds.forEach { Darwin.close($0) } }
        // A drain that never delivers must fail this test, not hang the runner: the read gives up after 2 s.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)

        let hangs = ScopeStackHangWatch()
        let target = DispatchQueue(label: "test.socket-writer.hang-scope")
        target.suspend()
        let writer = SocketWriter(fd: fds[0], label: "com.cmuxterm.next.daemon.write", qos: .userInitiated, target: target,
                                  hangs: hangs)
        defer { writer.close() }
        #expect(hangs.lanes == ["daemon.write"])
        #expect(SocketWriter.writeHangDeadline == .seconds(2))

        let first = await MainActor.run { [writer] in writer.write(Data("one\n".utf8)) }
        #expect(first == nil)
        // From a worker thread, behind the waiting line: it queues too.
        #expect(writer.write(Data("two\n".utf8)) == nil)
        #expect(writer.queuedBytes == 8)
        #expect(hangs.entered("daemon.write") == 0, "a write waiting for the drain queue opened a scope")
        target.resume()

        let expected = Array("one\ntwo\n".utf8)
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: expected.count)
        while received.count < expected.count {
            // A read bounded by SO_RCVTIMEO on the test's own socket.
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fds[1], $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            received += chunk[0 ..< count]
        }
        #expect(received == expected)
        // The drain is one block on the serial target: this one runs after it returned.
        target.sync {}

        #expect(hangs.entered("daemon.write") == 1, "two waiting control lines are one send, so one scope")
        #expect(hangs.open("daemon.write").isEmpty)
    }

    @Test func anIdleInlineWriteIsInNoScope() throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { fds.forEach { Darwin.close($0) } }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)

        let hangs = ScopeStackHangWatch()
        let writer = SocketWriter(fd: fds[0], label: "com.cmuxterm.next.daemon.write", qos: .userInitiated, hangs: hangs)
        defer { writer.close() }
        #expect(writer.write(Data("k\n".utf8)) == nil)

        var buffer = [UInt8](repeating: 0, count: 2)
        // A read bounded by SO_RCVTIMEO on the test's own socket.
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fds[1], $0.baseAddress, 2) }
        #expect(count == 2)
        #expect(buffer == Array("k\n".utf8))
        #expect(writer.queueHops == 0, "an idle write from a worker thread woke the drain queue")
        #expect(hangs.entered("daemon.write") == 0, "an inline send opened a drain-step scope")
    }

    @Test func noWatcherRegistersNothingAndStillWrites() throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { fds.forEach { Darwin.close($0) } }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)

        let writer = SocketWriter(fd: fds[0], label: "com.cmuxterm.next.daemon.write", qos: .userInitiated)
        defer { writer.close() }
        #expect(writer.write(Data("k\n".utf8)) == nil)

        var buffer = [UInt8](repeating: 0, count: 2)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fds[1], $0.baseAddress, 2) }
        #expect(count == 2)
        #expect(buffer == Array("k\n".utf8))
    }
}
