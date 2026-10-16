import Darwin
import Testing
@testable import CmuxFoundation

@Suite struct UnixSocketPeerCheckTests {
    @Test func readsTheConnectedPeerUserID() throws {
        let pair = try SocketPair()
        defer { pair.close() }

        #expect(UnixSocketPeerCheck().peerUserID(of: pair.first) == geteuid())
        #expect(UnixSocketPeerCheck().isTrustedPeer(pair.first))
    }

    @Test func refusesAPeerRunningAsAnotherUser() throws {
        let pair = try SocketPair()
        defer { pair.close() }

        #expect(!UnixSocketPeerCheck(expectedUserID: geteuid() &+ 1).isTrustedPeer(pair.first))
    }

    @Test func refusesADescriptorThatIsNotALocalSocket() throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
        }

        #expect(UnixSocketPeerCheck().peerUserID(of: fds[0]) == nil)
        #expect(!UnixSocketPeerCheck().isTrustedPeer(fds[0]))
    }

    private struct SocketPair {
        let first: Int32
        let second: Int32

        init() throws {
            var fds: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            first = fds[0]
            second = fds[1]
        }

        func close() {
            Darwin.close(first)
            Darwin.close(second)
        }
    }
}
