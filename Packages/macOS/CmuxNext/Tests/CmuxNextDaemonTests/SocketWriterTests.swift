import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// architecture.md 5a: a daemon that stops reading must not park the
/// writer's thread; bytes queue in order, bounded.
@Suite(.timeLimit(.minutes(1))) struct SocketWriterTests {
    func socketPair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    @Test func writesToAPeerThatDoesNotReadNeverBlockAndStayOrdered() async throws {
        let (local, remote) = socketPair()
        defer { close(local); close(remote) }
        let writer = SocketWriter(fd: local, label: "test.writer")
        defer { writer.close() }
        let chunk = 64 * 1024
        let started = ContinuousClock.now
        var expected = Data()
        for index in 0..<32 {
            let bytes = Data(repeating: UInt8(index), count: chunk)
            expected.append(bytes)
            #expect(writer.write(bytes) == nil)
        }
        // 2 MiB into a socket buffer of a few KB with nobody reading: no wait.
        #expect(ContinuousClock.now - started < .milliseconds(500))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while received.count < expected.count {
            let count = read(remote, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(buffer, count: count)
        }
        #expect(received == expected)
    }

    @Test func aBacklogPastTheLimitFailsInsteadOfGrowing() async throws {
        let (local, remote) = socketPair()
        defer { close(local); close(remote) }
        let writer = SocketWriter(fd: local, label: "test.writer", limit: 256 * 1024)
        defer { writer.close() }
        var failure: SocketWriteFailure?
        let started = ContinuousClock.now
        for _ in 0..<64 where failure == nil {
            failure = writer.write(Data(repeating: 1, count: 64 * 1024))
        }
        #expect(failure?.description.contains("not reading") == true)
        #expect(ContinuousClock.now - started < .milliseconds(500))
    }

    /// A peer that closed (daemon restart, CLI client gone) must give a
    /// "peer closed" failure, never SIGPIPE: the default action of SIGPIPE
    /// ends the whole process. The pair is made without SO_NOSIGPIPE, as any
    /// caller could hand one over; SocketWriter must protect itself.
    @Test func writingAfterThePeerClosedFailsWithoutKillingTheProcess() async throws {
        let (local, remote) = socketPair()
        defer { close(local) }
        close(remote)
        let writer = SocketWriter(fd: local, label: "test.writer")
        defer { writer.close() }
        var failure: SocketWriteFailure?
        let deadline = ContinuousClock.now + .seconds(5)
        while failure == nil, ContinuousClock.now < deadline {
            failure = writer.write(Data("ping\n".utf8))
            if failure == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(failure == .peerClosed)
    }
}
