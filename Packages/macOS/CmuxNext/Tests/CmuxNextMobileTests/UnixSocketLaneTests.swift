#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextMobile

/// The phone splice's lane to a daemon socket, on both platforms (Network.framework on macOS, a non-blocking
/// socket on libdispatch readiness on Linux): bytes both ways, the end of the stream, a typed failure for a
/// path nobody listens on, and a close that ends a waiting read.
@Suite(.timeLimit(.minutes(1))) struct UnixSocketLaneTests {
    /// A listening Unix socket at a short path in /tmp (sun_path is 104 bytes on Darwin).
    struct Listener {
        let path = "/tmp/ul-\(UUID().uuidString.prefix(8)).sock"
        let fd: Int32

        init() throws {
            #if canImport(Darwin)
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            #else
            fd = socket(AF_UNIX, Int32(truncatingIfNeeded: SOCK_STREAM.rawValue), 0)
            #endif
            let address = try #require(UnixSocketAddress(path: path))
            try #require(fd >= 0 && address.bind(fd) == 0 && listen(fd, 4) == 0)
        }

        /// The one pending connection (it is there before the call: the lane connected first).
        func acceptPeer() -> Int32 { accept(fd, nil, nil) }

        func stop() {
            _ = close(fd)
            unlink(path)
        }
    }

    @Test func bytesGoBothWaysAndThePeersCloseEndsTheStream() async throws {
        let listener = try Listener()
        defer { listener.stop() }
        let lane = try await UnixSocketLane.connect(path: listener.path)
        let peer = listener.acceptPeer()
        try #require(peer >= 0)
        defer { _ = close(peer) }

        let hello = Array("hello".utf8)
        #expect(write(peer, hello, hello.count) == hello.count)
        #expect(try await lane.read(maximumBytes: 64) == Data(hello))

        try await lane.write(Data("ping".utf8))
        let size = 16
        var buffer = [UInt8](repeating: 0, count: size)
        let count = read(peer, &buffer, size)
        #expect(count == 4 && Array(buffer.prefix(4)) == Array("ping".utf8))

        _ = shutdown(peer, Int32(SHUT_WR))
        #expect(try await lane.read(maximumBytes: 64) == nil)
        await lane.close()
    }

    @Test func aCloseEndsAWaitingRead() async throws {
        let listener = try Listener()
        defer { listener.stop() }
        let lane = try await UnixSocketLane.connect(path: listener.path)
        let peer = listener.acceptPeer()
        defer { _ = close(peer) }
        // Before or after the read starts waiting, the close ends it with no data.
        let reader = Task { try? await lane.read(maximumBytes: 64) }
        await lane.close()
        #expect(await reader.value == nil)
    }

    @Test func aPathNobodyListensOnIsATypedFailure() async {
        let path = "/tmp/ul-missing-\(UUID().uuidString.prefix(8)).sock"
        await #expect(throws: UnixSocketLane.Failure.self) {
            _ = try await UnixSocketLane.connect(path: path)
        }
    }
}
