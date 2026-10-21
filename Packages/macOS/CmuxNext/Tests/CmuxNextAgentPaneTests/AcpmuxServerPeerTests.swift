import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxServerPeerTests {
    @Test func anotherUsersSocketPeerIsRefusedBeforeItsExecutableOrSignature() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { descriptors.forEach { close($0) } }

        let peerUID = getuid()
        let anotherUID = peerUID == uid_t.max ? peerUID - 1 : peerUID + 1
        let result = AcpmuxServerPeer.check(
            descriptor: descriptors[0],
            executable: URL(fileURLWithPath: "/not-the-peer"),
            expectedUID: anotherUID
        )

        #expect(result == .failure(.otherUser(peerUID)))
    }
}
