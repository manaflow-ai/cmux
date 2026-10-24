import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextBridge
import Darwin
import Foundation
import Testing

/// A live `AgentActivityLineConnection` that its owner releases without `cancel()` ends: its socket
/// closes and the server reads end of file. The owners (AgentActivitySocketSource,
/// AgentTurnStateFeed) used to cancel their subscription in a deinit that did nothing off the main
/// thread; their deinit has no body now (`nonisolated deinit {}`), so the connection's own release
/// closes it, on the releasing thread. Before it, the descriptor and its read source stayed open
/// after the release.
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

    /// An owner released off the main thread (the last reference dropped by a background task):
    /// the feed's watch connection closes and acpmux reads end of file. The old deinit returned
    /// there without cancelling its subscription, so the socket stayed open. The main thread is
    /// blocked in the read while the release runs, so the close must happen on the releasing
    /// thread: an isolated (implicit) deinit would wait for the main actor and the read times out.
    @MainActor @Test func releasingTheTurnStateFeedOffTheMainThreadClosesItsWatch() async throws {
        let server = try ListeningSocket()
        defer { server.close() }
        let turns = AgentTurnStateStore(), lanes = AgentLaneStore()
        var feed: AgentTurnStateFeed? = AgentTurnStateFeed(socketPath: server.path, turns: turns, lanes: lanes)
        feed?.start(localHost: "install:release")
        let peer = try server.accept(within: 10)
        defer { Darwin.close(peer) }
        #expect(ListeningSocket.read(peer, within: 10)?.isEmpty == false, "the watch is live and sent its request")
        // The capture list holds the only reference, so the detached task drops the last one once
        // it is let go, while this (main) thread is blocked in the read below.
        let (go, letGo) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let release = Task.detached { [feed = Self.handOff(&feed)] in
            for await _ in go { break }
            _ = feed
        }
        #expect(feed == nil)
        letGo.yield()
        #expect(ListeningSocket.readsToEnd(peer, within: 10),
                "the released feed closed its watch on the releasing thread (end of file while the main thread waits)")
        await release.value
        withExtendedLifetime((turns, lanes)) {}
    }

    /// Moves the reference out of `value`: the caller's capture then holds the only one.
    private static func handOff<Value>(_ value: inout Value?) -> Value? {
        defer { value = nil }
        return value
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

    /// Whether `peer` reaches end of file (after whatever it still has to read) within `seconds` per read.
    static func readsToEnd(_ peer: Int32, within seconds: Int32) -> Bool {
        while let data = read(peer, within: seconds) {
            if data.isEmpty { return true }
        }
        return false
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
