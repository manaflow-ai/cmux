@testable import CmuxControlSocket
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
        var authorization = authorization
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        let capability = authority.issueCapability(
            nonce: Data(repeating: 0x5A, count: SocketClientCapabilityAuthority.secureByteCount)
        )
        let envelope = try #require(SocketClientCapabilityEnvelope(capability: capability))
        let command = "hooks claude prompt-submit"
        var ancestryEvaluationCount = 0

        #expect(authorization.authorizedCommand(
            envelope.wrap(command),
            peerProcessID: 123,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: { _ in
                ancestryEvaluationCount += 1
                return false
            }
        ) == command)
        #expect(ancestryEvaluationCount == 0)
    }

    @Test func cmuxOnlyRejectsReparentedClientWithoutCapability() {
        var authorization = authorization
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
        var authorization = authorization
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

    @Test func cmuxOnlyChecksOrdinaryDescendantAncestryOncePerConnection() {
        var authorization = authorization
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        var ancestryEvaluationCount = 0
        let isDescendant: (pid_t) -> Bool = { pid in
            ancestryEvaluationCount += 1
            return pid == 123
        }

        #expect(authorization.authorizedCommand(
            "ping",
            peerProcessID: 123,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: isDescendant
        ) == "ping")
        #expect(authorization.authorizedCommand(
            "system.capabilities",
            peerProcessID: 123,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: isDescendant
        ) == "system.capabilities")
        #expect(ancestryEvaluationCount == 1)
    }

    @Test func exhaustedPreauthorizationCachesDescendantForLaterCommands() {
        var authorization = authorization
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        var ancestryEvaluationCount = 0
        let isDescendant: (pid_t) -> Bool = { pid in
            ancestryEvaluationCount += 1
            return pid == 123
        }

        let admitted = authorization.cacheAncestryAuthorization(
            peerProcessID: 123,
            isDescendant: isDescendant
        )
        #expect(admitted)
        #expect(authorization.authorizedCommand(
            "ping",
            peerProcessID: 123,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: isDescendant
        ) == "ping")
        #expect(authorization.authorizedCommand(
            "system.capabilities",
            peerProcessID: 123,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: isDescendant
        ) == "system.capabilities")
        #expect(ancestryEvaluationCount == 1)
    }

    @Test func exhaustedPreauthorizationRejectsAndCachesNonDescendant() {
        var authorization = authorization
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        var ancestryEvaluationCount = 0
        let isDescendant: (pid_t) -> Bool = { _ in
            ancestryEvaluationCount += 1
            return false
        }

        let admitted = authorization.cacheAncestryAuthorization(
            peerProcessID: 123,
            isDescendant: isDescendant
        )
        #expect(!admitted)
        #expect(authorization.authorizedCommand(
            "ping",
            peerProcessID: 123,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: isDescendant
        ) == nil)
        #expect(ancestryEvaluationCount == 1)
    }
}
