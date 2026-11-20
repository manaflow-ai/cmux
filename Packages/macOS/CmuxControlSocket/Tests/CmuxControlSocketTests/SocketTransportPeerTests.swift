import CmuxControlSocket
import Darwin
import Foundation
import Testing

@Suite("SocketTransport peer verification")
struct SocketTransportPeerTests {
    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    @Test func peerProcessIDOfSelfConnectionIsOwnPid() throws {
        let transport = SocketTransport()
        let (a, b) = try makeSocketPair()
        defer {
            close(a)
            close(b)
        }
        #expect(transport.peerProcessID(of: a) == getpid())
    }

    @Test func peerHasSameUIDForSelfConnection() throws {
        let transport = SocketTransport()
        let (a, b) = try makeSocketPair()
        defer {
            close(a)
            close(b)
        }
        #expect(transport.peerHasSameUID(a))
    }

    @Test func peerAuditTokenIsAnImmutableExactProcessIdentity() throws {
        let transport = SocketTransport()
        let (a, b) = try makeSocketPair()
        defer {
            close(a)
            close(b)
        }
        let token = try #require(transport.peerAuditToken(of: a))
        #expect(token.bytes.count == SocketPeerAuditToken.byteCount)
        #expect(token.processID == getpid())
        #expect(token.processVersion != 0)
        #expect(transport.peerAuditToken(of: a) == token)
    }

    @Test func peerProcessIDFailsOnNonSocketDescriptor() {
        let transport = SocketTransport()
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        #expect(transport.peerProcessID(of: fd) == nil)
        #expect(!transport.peerHasSameUID(fd))
        #expect(transport.peerAuditToken(of: fd) == nil)
    }

    @Test func processDescendantWalk() {
        let transport = SocketTransport()
        let pid = getpid()
        #expect(transport.isProcessDescendant(pid, of: pid))
        // Our own process descends from launchd's tree root, not vice versa.
        #expect(!transport.isProcessDescendant(1, of: pid))
        #expect(transport.isProcessDescendant(pid, of: 1))
    }

    @Test func processStartTimeIsStableForCurrentProcess() throws {
        let transport = SocketTransport()
        let start = try #require(transport.processStartTime(of: getpid()))
        #expect(start.absoluteTime > 0)
        #expect(transport.processStartTime(of: getpid()) == start)
        #expect(transport.processStartTime(of: -1) == nil)
    }
}
