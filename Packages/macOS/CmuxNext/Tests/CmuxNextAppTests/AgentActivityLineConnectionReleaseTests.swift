import CmuxNextAgentActivity
import Darwin
import Foundation
import Testing

/// A live `AgentActivityLineConnection` that its owner releases without `cancel()` ends: its socket
/// closes and the server reads end of file. The owners (AgentActivitySocketSource,
/// AgentTurnStateFeed) used to cancel their subscription in a deinit that did nothing off the main
/// thread; they have no deinit now, so the connection's own release closes it. Before it, the
/// descriptor and its read source stayed open after the release.
@Suite(.timeLimit(.minutes(1)))
nonisolated struct AgentActivityLineConnectionReleaseTests {
    @Test func releasingALiveConnectionClosesItsSocket() throws {
        let server = try ListeningSocket()
        defer { server.close() }
        var connection: AgentActivityLineConnection? = AgentActivityLineConnection(path: server.path)
        connection?.start(send: Data("{}\n".utf8), onLine: { _ in }, onClose: {})
        let peer = try server.accept(within: 10)
        defer { Darwin.close(peer) }
        #expect(ListeningSocket.read(peer, within: 10) == Data("{}\n".utf8), "the connection is live and sent its request")
        connection = nil
        #expect(ListeningSocket.read(peer, within: 10) == Data(), "the released connection closed its socket (end of file)")
        #expect(connection == nil)
    }

    @Test func cancelStillClosesTheSocket() throws {
        let server = try ListeningSocket()
        defer { server.close() }
        let connection = AgentActivityLineConnection(path: server.path)
        connection.start(send: Data("{}\n".utf8), onLine: { _ in }, onClose: {})
        let peer = try server.accept(within: 10)
        defer { Darwin.close(peer) }
        #expect(ListeningSocket.read(peer, within: 10) == Data("{}\n".utf8))
        connection.cancel()
        #expect(ListeningSocket.read(peer, within: 10) == Data())
        withExtendedLifetime(connection) {}
    }
}

/// A listening unix socket in the temporary directory; reads and accepts wait at most a bound.
private nonisolated final class ListeningSocket {
    let path: String
    private let descriptor: Int32

    init() throws {
        path = NSTemporaryDirectory() + "release-\(UUID().uuidString.prefix(8)).sock"
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard descriptor >= 0, bound == 0, listen(descriptor, 4) == 0 else {
            throw POSIXError(.EADDRNOTAVAIL)
        }
    }

    /// The next connection, or a throw after `seconds`.
    func accept(within seconds: Int32) throws -> Int32 {
        guard Self.readable(descriptor, within: seconds) else { throw POSIXError(.ETIMEDOUT) }
        let peer = Darwin.accept(descriptor, nil, nil)
        guard peer >= 0 else { throw POSIXError(.ECONNABORTED) }
        return peer
    }

    /// What `peer` has to read (empty at end of file), or nil when nothing came within `seconds`.
    static func read(_ peer: Int32, within seconds: Int32) -> Data? {
        guard readable(peer, within: seconds) else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(peer, &buffer, buffer.count)
        return count >= 0 ? Data(buffer[0..<count]) : nil
    }

    private static func readable(_ fd: Int32, within seconds: Int32) -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, seconds * 1000) == 1
    }

    func close() {
        Darwin.close(descriptor)
        unlink(path)
    }
}
