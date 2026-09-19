@testable import CmuxControlSocket
import Foundation
import Testing

@Suite("Socket client capability proof")
struct SocketClientCapabilityProofTests {
    private let nonce = Data(repeating: 0x22, count: 32)
    private let challenge = Data(repeating: 0x33, count: 32)
    private let processID: pid_t = 1_234
    private let start: UInt64 = 0x0123_4567_89ab_cdef
    private let teamBinding = String(repeating: "ab", count: 32)
    private let expectedCapability =
        "v1.IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI.aJdag_LjWMM3t5g-yXUQxUVkq1hS2jCDRFanD3eKOHM"
    private let expectedClientProof =
        "5140afe6da1837ace4c75c67351979279a874e7a2fc2f437cbf67d59192deb8a"
    private let expectedServerProof =
        "7368ecb98b98b9191ca3366c33cef87b0f685257675b9f30ef9478283d1cd795"
    private let expectedTeamErrorProof =
        "c427eb3d5c096377c405c5124a9d2e647f7f97957007c5aac9a76551a42f62a1"

    @Test func knownAnswerAndDomainSeparatedRoundTrips() throws {
        let capability = authority(audience: "test.audience")
            .issueCapability(nonce: nonce)
        #expect(capability == expectedCapability)
        #expect(capability.utf8.count == 90)
        #expect(SocketClientCapabilityProof.capabilityNonce(from: capability)
            == nonce)

        let clientProof = try #require(SocketClientCapabilityProof.clientProof(
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start
        ))
        #expect(clientProof == expectedClientProof)
        #expect(SocketClientCapabilityProof.verifiesClientProof(
            clientProof,
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start
        ))

        let serverProof = try #require(SocketClientCapabilityProof.serverProof(
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start,
            teamBinding: teamBinding
        ))
        #expect(serverProof == expectedServerProof)
        #expect(SocketClientCapabilityProof.verifiesServerProof(
            serverProof,
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start,
            teamBinding: teamBinding
        ))
        #expect(!SocketClientCapabilityProof.verifiesServerProof(
            clientProof,
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start,
            teamBinding: teamBinding
        ))
        #expect(!SocketClientCapabilityProof.verifiesClientProof(
            serverProof,
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start
        ))
    }

    @Test func everyBoundFieldMutationRejects() throws {
        let capability = expectedCapability
        let clientProof = try #require(SocketClientCapabilityProof.clientProof(
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start
        ))
        #expect(!SocketClientCapabilityProof.verifiesClientProof(
            clientProof,
            capability: capability,
            nonce: nonce,
            challenge: Data(repeating: 0x34, count: 32),
            processID: processID,
            processStartAbsoluteTime: start
        ))
        #expect(!SocketClientCapabilityProof.verifiesClientProof(
            clientProof,
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID + 1,
            processStartAbsoluteTime: start
        ))
        #expect(!SocketClientCapabilityProof.verifiesClientProof(
            clientProof,
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start + 1
        ))

        let serverProof = try #require(SocketClientCapabilityProof.serverProof(
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start,
            teamBinding: teamBinding
        ))
        #expect(!SocketClientCapabilityProof.verifiesServerProof(
            serverProof,
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start,
            teamBinding: String(repeating: "ac", count: 32)
        ))

        let otherCapability = authority(audience: "other.audience")
            .issueCapability(nonce: nonce)
        #expect(!SocketClientCapabilityProof.verifiesClientProof(
            clientProof,
            capability: otherCapability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start
        ))
    }

    @Test func canonicalWireParsersRejectAlternateEncodings() {
        #expect(SocketClientCapabilityProof.encodeProcessStartTime(start)
            == "0123456789abcdef")
        #expect(SocketClientCapabilityProof.decodeProcessStartTime(
            "0123456789abcdef"
        ) == start)
        #expect(SocketClientCapabilityProof.decodeProcessStartTime(
            "123456789abcdef"
        ) == nil)
        #expect(SocketClientCapabilityProof.decodeProcessStartTime(
            "0123456789ABCDEF"
        ) == nil)
        #expect(SocketClientCapabilityProof.decodeProcessStartTime(
            "0000000000000000"
        ) == nil)
        let nonceText = SocketClientCapabilityProof.encodeBase64URL32(nonce)
        #expect(nonceText?.utf8.count == 43)
        #expect(SocketClientCapabilityProof.decodeBase64URL32(nonceText ?? "")
            == nonce)
        #expect(SocketClientCapabilityProof.decodeBase64URL32(
            (nonceText ?? "") + "="
        ) == nil)
        #expect(SocketClientCapabilityProof.capabilityNonce(
            from: expectedCapability + "="
        ) == nil)
    }

    @Test func signedErrorsAreAllowListedAndDomainSeparated() throws {
        let proof = try #require(SocketClientCapabilityProof.serverErrorProof(
            capability: expectedCapability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start,
            code: "team_required"
        ))
        #expect(proof == expectedTeamErrorProof)
        #expect(SocketClientCapabilityProof.verifiesServerErrorProof(
            proof,
            capability: expectedCapability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start,
            code: "team_required"
        ))
        #expect(!SocketClientCapabilityProof.verifiesServerErrorProof(
            proof,
            capability: expectedCapability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start,
            code: "coderouter_handoff_arm_busy"
        ))
        #expect(SocketClientCapabilityProof.serverErrorProof(
            capability: expectedCapability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start,
            code: "access_denied"
        ) == nil)
        #expect(!SocketClientCapabilityProof.verifiesServerProof(
            proof,
            capability: expectedCapability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: start,
            teamBinding: teamBinding
        ))
    }

    private func authority(audience: String) -> SocketClientCapabilityAuthority {
        SocketClientCapabilityAuthority(
            secret: Data(repeating: 0x11, count: 32),
            audience: audience
        )
    }
}
