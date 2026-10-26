@testable import CmuxNextDaemon
import Darwin
import Dispatch
import Foundation
import Testing

/// The daemon socket writer is on the key echo path: every typed key goes through its drain queue, and the
/// frame that shows the echo waits for it. At the default QoS a busy machine ran it behind utility work
/// (threading-model.md, QoS table: userInteractive is the main thread and the threads a frame waits for;
/// Chromium gives the threads input and display wait on the same class, base/threading/platform_thread_apple.mm).
@Suite struct SocketWriterQoSTests {
    @Test func theDrainQueueRunsAtUserInteractive() throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { fds.forEach { Darwin.close($0) } }

        let writer = SocketWriter(fd: fds[0], label: "com.cmuxterm.next.daemon.write")
        defer { writer.close() }

        #expect(writer.queueQoS == .userInteractive)
    }

    @Test func aWriteStillReachesThePeer() throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { fds.forEach { Darwin.close($0) } }

        let writer = SocketWriter(fd: fds[0], label: "com.cmuxterm.next.daemon.write")
        defer { writer.close() }
        #expect(writer.write(Data("k\n".utf8)) == nil)

        var buffer = [UInt8](repeating: 0, count: 2)
        // A blocking read on the test's own socket: the writer's queue sends the two bytes.
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fds[1], $0.baseAddress, 2) }
        #expect(count == 2)
        #expect(buffer == Array("k\n".utf8))
    }
}
