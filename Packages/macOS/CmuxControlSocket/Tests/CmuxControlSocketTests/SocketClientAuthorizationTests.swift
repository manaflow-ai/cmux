@testable import CmuxControlSocket
import CmuxSettings
import Foundation
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

    @Test func cmuxOnlyAllowsReparentedClientWithInheritedCapability() throws {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        let capability = authority.issueCapability(
            nonce: Data(repeating: 0x5A, count: SocketClientCapabilityAuthority.secureByteCount)
        )
        let envelope = try #require(SocketClientCapabilityEnvelope(capability: capability))
        let command = "hooks claude prompt-submit"

        #expect(authorization.authorizedCommand(
            envelope.wrap(command),
            peerProcessID: 123,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == command)
    }

    @Test func cmuxOnlyRejectsReparentedClientWithoutCapability() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        #expect(authorization.authorizedCommand(
            "hooks claude prompt-submit",
            peerProcessID: 123,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == nil)
    }

    @Test func cmuxOnlyRejectsCapabilityFromDifferentUser() throws {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        let capability = authority.issueCapability(
            nonce: Data(repeating: 0x5A, count: SocketClientCapabilityAuthority.secureByteCount)
        )
        let envelope = try #require(SocketClientCapabilityEnvelope(capability: capability))
        #expect(authorization.authorizedCommand(
            envelope.wrap("hooks claude prompt-submit"),
            peerProcessID: 123,
            peerHasSameUID: false,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == nil)
    }

    @Test func ownerOnlyAutomationModesRejectDifferentUser() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )

        for mode in [SocketControlMode.automation, .password] {
            #expect(authorization.authorizedCommand(
                "ping",
                accessMode: mode,
                peerProcessID: nil,
                peerHasSameUID: false,
                capabilityAuthority: authority,
                isDescendant: { _ in false }
            ) == nil)
        }
    }

    @Test func ownerOnlyAutomationModesAllowSameUser() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )

        for mode in [SocketControlMode.automation, .password] {
            #expect(authorization.authorizedCommand(
                "ping",
                accessMode: mode,
                peerProcessID: nil,
                peerHasSameUID: true,
                capabilityAuthority: authority,
                isDescendant: { _ in false }
            ) == "ping")
        }
    }

    @Test func allowAllDoesNotRequireSameUser() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )

        #expect(authorization.authorizedCommand(
            "ping",
            accessMode: .allowAll,
            peerProcessID: nil,
            peerHasSameUID: false,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == "ping")
    }

    /// `allowAll` widens who may connect to the socket, not what a caller
    /// reaches: the browser REPL drives the user's browser profile (cookies,
    /// tabs) and files, so a peer of another user is refused in every mode,
    /// also once `allowAll` admitted its command.
    @Test func browserReplRequiresSameUserEvenWhenAllowAllAdmitsThePeer() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        let command = #"{"id":1,"method":"browser.repl.eval","params":{}}"#
        #expect(authorization.authorizedCommand(
            command,
            accessMode: .allowAll,
            peerProcessID: 123,
            peerHasSameUID: false,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == command)
        for method in ["browser.repl.eval", "browser.repl.reset", "browser.repl.list"] {
            #expect(!authorization.admitsMethod(method, peerHasSameUID: false), "\(method)")
            #expect(authorization.admitsMethod(method, peerHasSameUID: true), "\(method)")
            #expect(authorization.admitsMethod(method, peerHasSameUID: nil), "\(method)")
        }
        #expect(authorization.admitsMethod("system.ping", peerHasSameUID: false))
    }
}

