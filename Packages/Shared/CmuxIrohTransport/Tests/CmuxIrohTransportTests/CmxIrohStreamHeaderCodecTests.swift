import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohStreamHeaderCodecTests {
    @Test
    func pairGrantControlRoundTripsWithoutConsumingApplicationBytes() throws {
        let codec = try CmxIrohStreamHeaderCodec()
        let credential = try CmxIrohAdmissionCredential.pairGrant("e30.e30.AA")
        let header = try CmxIrohStreamHeader(lane: .control, credential: credential)
        let encoded = try codec.encode(header)
        let applicationBytes = Data([0xde, 0xad, 0xbe, 0xef])

        let decoded = try codec.decodePrefix(encoded + applicationBytes)

        #expect(decoded.header == header)
        #expect(decoded.consumedByteCount == encoded.count)
        #expect((encoded + applicationBytes).dropFirst(decoded.consumedByteCount) == applicationBytes)
    }

    @Test
    func offlinePairingControlRoundTripsAttestationInvitationAndProof() throws {
        let codec = try CmxIrohStreamHeaderCodec()
        let invitationID = try CmxIrohResourceID("invite:42")
        let credential = try CmxIrohAdmissionCredential.offlinePairing(
            endpointAttestation: "eyJraWQiOiJrMSJ9.e30.AA",
            invitationID: invitationID,
            proof: Data(repeating: 0x5a, count: 32)
        )
        let header = try CmxIrohStreamHeader(lane: .control, credential: credential)

        #expect(try codec.decodePrefix(codec.encode(header)).header == header)
    }

    @Test
    func multistreamLanesRoundTrip() throws {
        let codec = try CmxIrohStreamHeaderCodec()
        let terminalID = try CmxIrohResourceID("terminal:1")
        let artifactID = try CmxIrohResourceID("artifact.preview:2")
        let lanes: [CmxIrohLane] = [
            .serverEvents(cursor: nil),
            .serverEvents(cursor: 91),
            .terminal(resourceID: terminalID, cursor: nil),
            .terminal(resourceID: terminalID, cursor: 4_096),
            .artifact(resourceID: artifactID, offset: 8_192),
        ]

        for lane in lanes {
            let header = try CmxIrohStreamHeader(lane: lane)
            #expect(try codec.decodePrefix(codec.encode(header)).header == header)
        }
    }

    @Test
    func controlRequiresCredentialAndOtherLanesRejectIt() throws {
        #expect(throws: CmxIrohStreamHeaderError.missingControlCredential) {
            try CmxIrohStreamHeader(lane: .control)
        }

        let credential = try CmxIrohAdmissionCredential.pairGrant("e30.e30.AA")
        #expect(throws: CmxIrohStreamHeaderError.credentialOnNonControlLane) {
            try CmxIrohStreamHeader(
                lane: .serverEvents(cursor: nil),
                credential: credential
            )
        }
    }

    @Test
    func incompleteFrameReportsTheExactNextRequiredLength() throws {
        let codec = try CmxIrohStreamHeaderCodec()
        let header = try CmxIrohStreamHeader(
            lane: .control,
            credential: .pairGrant("e30.e30.AA")
        )
        let encoded = try codec.encode(header)

        #expect(throws: CmxIrohStreamHeaderCodecError.incompleteFrame(requiredByteCount: 16)) {
            try codec.decodePrefix(encoded.prefix(15))
        }
        #expect(throws: CmxIrohStreamHeaderCodecError.incompleteFrame(requiredByteCount: encoded.count)) {
            try codec.decodePrefix(encoded.dropLast())
        }
    }

    @Test
    func malformedPrefixAndReservedFieldsFailClosed() throws {
        let codec = try CmxIrohStreamHeaderCodec()
        let terminal = try CmxIrohStreamHeader(
            lane: .terminal(resourceID: CmxIrohResourceID("terminal:1"), cursor: nil)
        )
        let baseline = try codec.encode(terminal)

        var invalidMagic = baseline
        invalidMagic[invalidMagic.startIndex] ^= 0xff
        #expect(throws: CmxIrohStreamHeaderCodecError.invalidMagic) {
            try codec.decodePrefix(invalidMagic)
        }

        var invalidVersion = baseline
        invalidVersion[invalidVersion.startIndex + 8] = 2
        #expect(throws: CmxIrohStreamHeaderCodecError.unsupportedVersion(2)) {
            try codec.decodePrefix(invalidVersion)
        }

        var unknownLane = baseline
        unknownLane[unknownLane.startIndex + 9] = 99
        #expect(throws: CmxIrohStreamHeaderCodecError.unknownLane(99)) {
            try codec.decodePrefix(unknownLane)
        }

        var reservedFlags = baseline
        reservedFlags[reservedFlags.startIndex + 10] = 0x80
        #expect(throws: CmxIrohStreamHeaderCodecError.invalidFlags(0x80)) {
            try codec.decodePrefix(reservedFlags)
        }

        var secondCredential = baseline
        secondCredential[secondCredential.startIndex + 11] = 1
        #expect(throws: CmxIrohStreamHeaderCodecError.invalidCredentialKind(1)) {
            try codec.decodePrefix(secondCredential)
        }
    }

    @Test
    func declaredOversizeHeaderIsRejectedBeforeBufferingPayload() throws {
        let codec = try CmxIrohStreamHeaderCodec(
            configuration: CmxIrohProtocolConfiguration(
                alpn: Data("test".utf8),
                maximumHeaderByteCount: 32
            )
        )
        var prefix = Data("CMUXIRH1".utf8)
        prefix.append(contentsOf: [1, 1, 0, 1, 0, 0, 1, 0])

        #expect(throws: CmxIrohStreamHeaderCodecError.headerTooLarge(272)) {
            try codec.decodePrefix(prefix)
        }
    }

    @Test
    func credentialAndResourceValidationRejectsAmbiguousValues() throws {
        #expect(throws: CmxIrohAdmissionCredentialError.invalidSignedToken) {
            try CmxIrohAdmissionCredential.pairGrant("not-a-jws")
        }
        #expect(throws: CmxIrohAdmissionCredentialError.invalidOfflineProofLength(31)) {
            try CmxIrohAdmissionCredential.offlinePairing(
                endpointAttestation: "e30.e30.AA",
                invitationID: CmxIrohResourceID("invite"),
                proof: Data(repeating: 0, count: 31)
            )
        }
        #expect(throws: CmxIrohResourceIDError.invalidValue) {
            try CmxIrohResourceID("device name")
        }
    }

    @Test
    func payloadMustBeConsumedExactly() throws {
        let codec = try CmxIrohStreamHeaderCodec()
        let header = try CmxIrohStreamHeader(lane: .serverEvents(cursor: nil))
        var frame = try codec.encode(header)
        frame[frame.startIndex + 15] = 1
        frame.append(0)

        #expect(throws: CmxIrohStreamHeaderCodecError.invalidPayload) {
            try codec.decodePrefix(frame)
        }
    }
}
