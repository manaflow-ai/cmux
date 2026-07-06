import CmuxControlSocket
import Testing

@Suite("Socket client authorization")
struct SocketClientAuthorizationTests {
    @Test func cmuxOnlyFailsClosedWhenPeerPidIsUnavailable() {
        #expect(!SocketClientAuthorization.isCmuxOnlyClientAllowed(
            peerProcessID: nil,
            peerHasSameUID: true,
            isDescendant: { _ in true }
        ))
    }

    @Test func cmuxOnlyAllowsDescendantPeerPid() {
        #expect(SocketClientAuthorization.isCmuxOnlyClientAllowed(
            peerProcessID: 123,
            peerHasSameUID: false,
            isDescendant: { $0 == 123 }
        ))
    }

    @Test func cmuxOnlyRejectsNonDescendantPeerPid() {
        #expect(!SocketClientAuthorization.isCmuxOnlyClientAllowed(
            peerProcessID: 123,
            peerHasSameUID: true,
            isDescendant: { _ in false }
        ))
    }
}
