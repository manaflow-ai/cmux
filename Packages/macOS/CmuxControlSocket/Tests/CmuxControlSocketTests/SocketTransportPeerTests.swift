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

    @Test func peerProcessIDFailsOnNonSocketDescriptor() {
        let transport = SocketTransport()
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        #expect(transport.peerProcessID(of: fd) == nil)
        #expect(!transport.peerHasSameUID(fd))
    }

    @Test func processDescendantWalk() {
        let transport = SocketTransport()
        let pid = getpid()
        #expect(transport.isProcessDescendant(pid, of: pid))
        // Our own process descends from launchd's tree root, not vice versa.
        #expect(!transport.isProcessDescendant(1, of: pid))
        #expect(transport.isProcessDescendant(pid, of: 1))
    }
}
