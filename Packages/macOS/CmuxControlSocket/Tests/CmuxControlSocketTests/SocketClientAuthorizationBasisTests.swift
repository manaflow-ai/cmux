@testable import CmuxControlSocket
import CmuxSettings
import Foundation
import Testing

@Suite("Socket client authorization basis")
struct SocketClientAuthorizationBasisTests {
    private let authorization = SocketClientAuthorization()
    private let audience = "com.cmuxterm.authorization-basis-tests"

    @Test func validCapabilityHasVerifiedBasisAcrossEnabledModes() throws {
        let authority = makeAuthority(byte: 0x31)
        let command = "agent.sidecar.start"
        let envelope = try #require(SocketClientCapabilityEnvelope(
            capability: authority.issueCapability(
                nonce: Data(
                    repeating: 0x73,
                    count: SocketClientCapabilityAuthority.secureByteCount
                )
            )
        ))

        for mode in [
            SocketControlMode.cmuxOnly,
            .password,
            .automation,
            .allowAll,
        ] {
            let result = authorization.authorizedCommandResult(
                envelope.wrap(command),
                accessMode: mode,
                peerProcessID: 412,
                peerHasSameUID: true,
                capabilityAuthority: authority,
                isDescendant: { _ in false }
            )

            #expect(result?.command == command)
            #expect(result?.basis == .verifiedCapability)
        }
    }

    @Test func validCapabilityTakesPrecedenceOverDescendantBasis() throws {
        let authority = makeAuthority(byte: 0x32)
        let envelope = try #require(SocketClientCapabilityEnvelope(
            capability: authority.issueCapability(
                nonce: Data(
                    repeating: 0x74,
                    count: SocketClientCapabilityAuthority.secureByteCount
                )
            )
        ))

        let result = authorization.authorizedCommandResult(
            envelope.wrap("system.ping"),
            accessMode: .cmuxOnly,
            peerProcessID: 413,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: { $0 == 413 }
        )

        #expect(result?.basis == .verifiedCapability)
    }

    @Test func fakeAndRawCommandsRetainOnlyTheirModeAuthority() throws {
        let authority = makeAuthority(byte: 0x33)
        let fakeEnvelope = try #require(SocketClientCapabilityEnvelope(
            capability: "v1.not-a-valid-capability.signature"
        ))
        let command = "system.ping"

        for input in [fakeEnvelope.wrap(command), command] {
            let descendant = authorization.authorizedCommandResult(
                input,
                accessMode: .cmuxOnly,
                peerProcessID: 414,
                peerHasSameUID: true,
                capabilityAuthority: authority,
                isDescendant: { $0 == 414 }
            )
            #expect(descendant?.command == command)
            #expect(descendant?.basis == .descendant)

            for mode in [SocketControlMode.password, .automation] {
                let sameOwner = authorization.authorizedCommandResult(
                    input,
                    accessMode: mode,
                    peerProcessID: 414,
                    peerHasSameUID: true,
                    capabilityAuthority: authority,
                    isDescendant: { _ in false }
                )
                #expect(sameOwner?.command == command)
                #expect(sameOwner?.basis == .sameOwner)
            }

            let unrestricted = authorization.authorizedCommandResult(
                input,
                accessMode: .allowAll,
                peerProcessID: 414,
                peerHasSameUID: false,
                capabilityAuthority: authority,
                isDescendant: { _ in false }
            )
            #expect(unrestricted?.command == command)
            #expect(unrestricted?.basis == .unrestricted)
        }
    }

    @Test func nonDescendantCmuxOnlyClientCannotUseFakeOrRawCommand() throws {
        let authority = makeAuthority(byte: 0x34)
        let fakeEnvelope = try #require(SocketClientCapabilityEnvelope(
            capability: "v1.not-a-valid-capability.signature"
        ))

        for input in [fakeEnvelope.wrap("system.ping"), "system.ping"] {
            #expect(authorization.authorizedCommandResult(
                input,
                accessMode: .cmuxOnly,
                peerProcessID: 415,
                peerHasSameUID: true,
                capabilityAuthority: authority,
                isDescendant: { _ in false }
            ) == nil)
        }
    }

    @Test func authorityRotationRevokesVerifiedBasisForOldToken() throws {
        let original = makeAuthority(byte: 0x35)
        let rotated = makeAuthority(byte: 0x36)
        let envelope = try #require(SocketClientCapabilityEnvelope(
            capability: original.issueCapability(
                nonce: Data(
                    repeating: 0x75,
                    count: SocketClientCapabilityAuthority.secureByteCount
                )
            )
        ))
        let command = envelope.wrap("agent.sidecar.start")

        #expect(authorization.authorizedCommandResult(
            command,
            accessMode: .cmuxOnly,
            peerProcessID: 416,
            peerHasSameUID: true,
            capabilityAuthority: rotated,
            isDescendant: { _ in false }
        ) == nil)

        for mode in [SocketControlMode.password, .automation] {
            #expect(authorization.authorizedCommandResult(
                command,
                accessMode: mode,
                peerProcessID: 416,
                peerHasSameUID: true,
                capabilityAuthority: rotated,
                isDescendant: { _ in false }
            )?.basis == .sameOwner)
        }

        #expect(authorization.authorizedCommandResult(
            command,
            accessMode: .allowAll,
            peerProcessID: 416,
            peerHasSameUID: false,
            capabilityAuthority: rotated,
            isDescendant: { _ in false }
        )?.basis == .unrestricted)
    }

    @Test func resultAndBasisAreSendable() {
        requireSendable(SocketClientAuthorizationBasis.verifiedCapability)
        requireSendable(SocketClientAuthorizationResult(
            command: "system.ping",
            basis: .sameOwner
        ))
    }

    private func makeAuthority(byte: UInt8) -> SocketClientCapabilityAuthority {
        SocketClientCapabilityAuthority(
            secret: Data(
                repeating: byte,
                count: SocketClientCapabilityAuthority.secureByteCount
            ),
            audience: audience
        )
    }

    private func requireSendable<T: Sendable>(_: T) {}
}
