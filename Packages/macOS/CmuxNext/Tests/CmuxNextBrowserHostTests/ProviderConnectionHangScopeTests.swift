@testable import CmuxNextBrowserHost
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// The browser-host provider connection registers two lanes: the reader's decode and hand-off of each chunk is
/// one `browser-host.provider.read` scope and each write job's build and encode one `browser-host.provider.write`
/// scope, 1 s each; the reader's `read(2)` and the writer's `write(2)` are in none, and both lanes are freed with
/// the connection (plans/cmux-next/chrome-parity/p09-observability.md, section E, task 119).
@Suite(.timeLimit(.minutes(1)))
struct ProviderConnectionHangScopeTests {
    nonisolated static let read = "browser-host.provider.read"
    nonisolated static let write = "browser-host.provider.write"

    /// A connected pair: the connection's end and the test's end (reads bounded by a 10 s receive timeout).
    private static func pair() throws -> (connection: Int32, peer: Int32) {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return (fds[0], fds[1])
    }

    private static func send(_ frame: ProviderFrame, to fd: Int32) throws {
        let bytes = try ProviderCodec.encode(frame)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        #expect(written == bytes.count)
    }

    @Test func eachChunkReadIsOneScopeAndTheReadIsNone() async throws {
        let (fd, peer) = try Self.pair()
        defer { Darwin.close(peer) }
        let hangs = RecordingLaneHangWatch()
        let connection = ProviderConnection(fd: fd, hangs: hangs)
        defer { connection.close() }
        #expect(hangs.lanes == [Self.read, Self.write])
        #expect(ProviderConnection.hangDeadline == .seconds(1))
        connection.start()

        var frames = connection.frames.makeAsyncIterator()
        try Self.send(.userInput(targetID: "a"), to: peer)
        #expect(await frames.next() == .userInput(targetID: "a"))
        try Self.send(.userInput(targetID: "b"), to: peer)
        #expect(await frames.next() == .userInput(targetID: "b"))
        // One scope per chunk; a scope around the wait in read(2) would have opened a third by now.
        #expect(hangs.entered(Self.read) == 2)
        #expect(hangs.entered.allSatisfy { $0.deadline == .seconds(1) })
    }

    @Test func aWriteJobsBuildIsOneScopeAndItsWriteIsNone() async throws {
        let (fd, peer) = try Self.pair()
        defer { Darwin.close(peer) }
        let hangs = RecordingLaneHangWatch()
        let connection = ProviderConnection(fd: fd, hangs: hangs)
        defer { connection.close() }

        let (depths, depth) = AsyncStream.makeStream(of: Int.self)
        let queued = connection.send(building: {
            depth.yield(hangs.open(Self.write).count)
            return [ProviderFrame.userInput(targetID: "w")]
        })
        #expect(queued)
        var built = depths.makeAsyncIterator()
        #expect(await built.next() == 1, "the build ran outside the write lane's scope")

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(peer, $0.baseAddress, $0.count) }
        var decoder = ProviderFrameDecoder()
        decoder.push(Data(buffer.prefix(max(count, 0))))
        #expect(try decoder.next() == .userInput(targetID: "w"))
        #expect(hangs.entered(Self.write) == 1)
    }

    @Test func bothLanesAreFreedWithTheConnection() throws {
        let (fd, peer) = try Self.pair()
        defer { Darwin.close(peer) }
        let hangs = RecordingLaneHangWatch()
        var connection: ProviderConnection? = ProviderConnection(fd: fd, hangs: hangs)
        #expect(connection != nil)
        connection = nil
        #expect(hangs.unregistered == [Self.read, Self.write])
    }
}
