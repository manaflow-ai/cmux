import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxServerPeerTests {
    @Test func anotherUsersSocketPeerIsRefusedBeforeItsExecutableOrSignature() throws {
        try withSocketPair { descriptor in
            let peerUID = getuid()
            let anotherUID = peerUID == uid_t.max ? peerUID - 1 : peerUID + 1
            let result = AcpmuxServerPeer.check(
                descriptor: descriptor,
                executable: URL(fileURLWithPath: "/not-the-peer"),
                expectedUID: anotherUID
            )

            #expect(result == .failure(.otherUser(peerUID)))
        }
    }

    /// "acpmux is too belt and suspenders there" (Leo): a same-user peer at this app's acpmux
    /// path is usable with no code-signing requirement (the test runner is not Team-signed).
    @Test func aSameUserPeerAtTheAppsPathIsUsableWithoutASignatureGate() throws {
        try withSocketPair { descriptor in
            let result = AcpmuxServerPeer.check(descriptor: descriptor, executable: try ownExecutable())

            #expect(result == .success(.own))
        }
    }

    @Test func aSameUserPeerAtAnotherPathIsAnotherInstallOnlyWhenTheCallerAllowsIt() throws {
        try withSocketPair { descriptor in
            let other = URL(fileURLWithPath: "/not-the-peer")
            let peerPath = try ownExecutable().path

            #expect(AcpmuxServerPeer.check(descriptor: descriptor, executable: other, allowForeign: true) == .success(.foreign))
            #expect(AcpmuxServerPeer.check(descriptor: descriptor, executable: other) == .failure(.otherExecutable(peerPath)))
        }
    }

    /// The peer of a socketpair end is this test process.
    private func withSocketPair(_ body: (Int32) throws -> Void) throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { descriptors.forEach { close($0) } }
        try body(descriptors[0])
    }

    private func ownExecutable() throws -> URL {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try #require(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0)
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }
}
