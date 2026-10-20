import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct UnixSocketConnectProbeTests {
    @Test func acceptsThisUsersListener() throws {
        let listener = try Listener()
        defer { listener.remove() }

        #expect(UnixSocketConnectProbe().acceptsConnections(atPath: listener.path))
    }

    @Test func refusesAListenerRunningAsAnotherUser() throws {
        let listener = try Listener()
        defer { listener.remove() }
        let probe = UnixSocketConnectProbe(peerCheck: UnixSocketPeerCheck(expectedUserID: geteuid() &+ 1))

        #expect(!probe.acceptsConnections(atPath: listener.path))
    }

    @Test func refusesAMissingPath() throws {
        let listener = try Listener()
        listener.remove()

        #expect(!UnixSocketConnectProbe().acceptsConnections(atPath: listener.path))
    }

    /// A listening socket in a short private directory under `/tmp`, since the
    /// per-user temporary directory is too long for a socket path.
    private struct Listener {
        let directory: String
        let path: String
        let fd: Int32

        init() throws {
            var template = Array("/tmp/cmux-probe.XXXXXX".utf8CString)
            guard let created = mkdtemp(&template) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            directory = String(cString: created)
            path = directory + "/s.sock"
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(fd >= 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
                path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
            }
            let bound = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(bound == 0)
            try #require(listen(fd, 4) == 0)
        }

        func remove() {
            Darwin.close(fd)
            unlink(path)
            rmdir(directory)
        }
    }
}
