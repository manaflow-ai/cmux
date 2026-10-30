import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// Austin's nightly-next (2026-10-29, #27698): about 80 terminal agents held all 64 of the daemon's
/// connections, and the app's own connections were refused with theirs. The daemon now has a
/// socket for the app alone, `<session socket>.app`, next to the session socket that terminals,
/// the CLI and hooks use. Every app connection to a session socket goes there when the daemon has
/// one, and to the session socket when it has none (an older daemon) or the file is stale.
@Suite struct AppLaneConnectionTests {
    /// A listening Unix socket at `path`; nothing is accepted, so pending connections stay queued.
    final class Listener {
        let fd: Int32
        let path: String

        init(path: String, listening: Bool = true) throws {
            self.path = path
            fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EBADF) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, !listening || Darwin.listen(fd, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        }

        /// A client connected and waits to be accepted.
        var hasPendingConnection: Bool {
            var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            return Darwin.poll(&poll, 1, 0) > 0 && poll.revents & Int16(POLLIN) != 0
        }

        deinit {
            Darwin.close(fd)
            unlink(path)
        }
    }

    /// A short private directory, so socket paths fit `sun_path`.
    private static func directory() throws -> String {
        var template = Array("/tmp/cxal-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError(.ENOENT) }
        return String(cString: made)
    }

    @Test func theAppConnectsOnItsOwnSocketWhenTheDaemonHasOne() throws {
        let directory = try Self.directory()
        defer { rmdir(directory) }
        let session = try Listener(path: directory + "/s.sock")
        let app = try Listener(path: session.path + ".app")
        let transport = try LineTransport(path: session.path)
        defer { transport.close() }
        #expect(app.hasPendingConnection, "the app's connection did not use the daemon's app socket")
        #expect(!session.hasPendingConnection, "the app took a connection on the session socket")
    }

    @Test func withoutAnAppSocketTheAppUsesTheSessionSocket() throws {
        let directory = try Self.directory()
        defer { rmdir(directory) }
        let session = try Listener(path: directory + "/s.sock")
        let transport = try LineTransport(path: session.path)
        defer { transport.close() }
        #expect(session.hasPendingConnection)
    }

    /// A crashed daemon leaves its app socket file behind with no listener.
    @Test func aStaleAppSocketFallsBackToTheSessionSocket() throws {
        let directory = try Self.directory()
        defer { rmdir(directory) }
        let session = try Listener(path: directory + "/s.sock")
        let stale = try Listener(path: session.path + ".app", listening: false)
        let transport = try LineTransport(path: session.path)
        defer { transport.close() }
        #expect(session.hasPendingConnection)
        #expect(!stale.hasPendingConnection)
    }
}
