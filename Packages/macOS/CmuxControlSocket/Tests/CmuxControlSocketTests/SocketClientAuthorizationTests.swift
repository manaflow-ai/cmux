import CmuxControlSocket
import Testing

@Suite("Socket client authorization")
struct SocketClientAuthorizationTests {
    private let authorization = SocketClientAuthorization()

    @Test func cmuxOnlyFailsClosedWhenPeerPidIsUnavailable() {
        #expect(!authorization.isCmuxOnlyClientAllowed(
            peerProcessID: nil,
            peerHasSameUID: true,
            isDescendant: { _ in true }
        ))
    }

    @Test func cmuxOnlyAllowsDescendantPeerPid() {
        #expect(authorization.isCmuxOnlyClientAllowed(
            peerProcessID: 123,
            peerHasSameUID: false,
            isDescendant: { $0 == 123 }
        ))
    }

    @Test func cmuxOnlyRejectsNonDescendantPeerPid() {
        #expect(!authorization.isCmuxOnlyClientAllowed(
            peerProcessID: 123,
            peerHasSameUID: true,
            isDescendant: { _ in false }
        ))
    }
}
