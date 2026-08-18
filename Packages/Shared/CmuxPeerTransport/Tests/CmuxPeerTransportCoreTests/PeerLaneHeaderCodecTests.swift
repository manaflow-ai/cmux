import Foundation
import Testing

@testable import CmuxPeerTransportCore

@Suite struct PeerLaneHeaderCodecTests {
    private static let validToken = "e30.e30.AA"

    private func makeCredential() throws -> PeerPairGrantCredential {
        try PeerPairGrantCredential(token: Self.validToken)
    }

    // MARK: Round trips

    @Test func pairGrantControlRoundTripsWithoutConsumingApplicationBytes() throws {
        let codec = try PeerLaneHeaderCodec()
        let header = PeerLaneHeader.control(credential: try makeCredential())
        let encoded = try codec.encode(header)
        let applicationBytes = Data([0xde, 0xad, 0xbe, 0xef])

        let decoded = try codec.decodePrefix(encoded + applicationBytes)

        #expect(decoded.header == header)
        #expect(decoded.consumedByteCount == encoded.count)
        #expect((encoded + applicationBytes).dropFirst(decoded.consumedByteCount) == applicationBytes)
    }

    @Test func everyLaneRoundTrips() throws {
        let codec = try PeerLaneHeaderCodec()
        let terminalID = try PeerResourceID("terminal:1")
        let artifactID = try PeerResourceID("artifact.preview:2")
        let headers: [PeerLaneHeader] = [
            .control(credential: try makeCredential()),
            .serverEvents(cursor: nil),
            .serverEvents(cursor: 91),
            .serverEvents(cursor: .max),
            .terminal(resourceID: terminalID, cursor: nil),
            .terminal(resourceID: terminalID, cursor: 4_096),
            .artifact(resourceID: artifactID, offset: 0),
            .artifact(resourceID: artifactID, offset: 8_192),
        ]

        for header in headers {
            let encoded = try codec.encode(header)
            let decoded = try codec.decodePrefix(encoded + Data([0xff]))
            #expect(decoded.header == header)
            #expect(decoded.consumedByteCount == encoded.count)
        }
    }

    @Test func frameBeginsWithTheConfiguredMagicAndVersion() throws {
        let codec = try PeerLaneHeaderCodec()
        let encoded = try codec.encode(.serverEvents(cursor: nil))

        #expect(encoded.prefix(8) == Data("CMUXPRT2".utf8))
        #expect(encoded[encoded.startIndex + 8] == 1)
        #expect(PeerProtocolConfiguration.cmuxMobileV2.alpn == Data("cmux/mobile/2".utf8))
    }

    // MARK: Credential discipline on the wire

    @Test func controlFrameWithoutCredentialCodeIsRejected() throws {
        let codec = try PeerLaneHeaderCodec()
        var frame = try codec.encode(.control(credential: try makeCredential()))
        frame[frame.startIndex + 11] = 0

        #expect(throws: PeerLaneHeaderCodecError.invalidCredentialKind(0)) {
            try codec.decodePrefix(frame)
        }
    }

    @Test func droppedOfflinePairingCredentialKindFailsClosed() throws {
        let codec = try PeerLaneHeaderCodec()
        var frame = try codec.encode(.control(credential: try makeCredential()))
        // Credential kind 2 was legacy offline pairing; v3 deletes it.
        frame[frame.startIndex + 11] = 2

        #expect(throws: PeerLaneHeaderCodecError.invalidCredentialKind(2)) {
            try codec.decodePrefix(frame)
        }
    }

    @Test func nonControlLanesRejectACredential() throws {
        let codec = try PeerLaneHeaderCodec()
        for header in [
            PeerLaneHeader.serverEvents(cursor: nil),
            PeerLaneHeader.terminal(resourceID: try PeerResourceID("t:1"), cursor: nil),
            PeerLaneHeader.artifact(resourceID: try PeerResourceID("a:1"), offset: 0),
        ] {
            var frame = try codec.encode(header)
            frame[frame.startIndex + 11] = 1
            #expect(throws: PeerLaneHeaderCodecError.invalidCredentialKind(1)) {
                try codec.decodePrefix(frame)
            }
        }
    }

    @Test func controlTokenMustBeACompactJWS() throws {
        let codec = try PeerLaneHeaderCodec()
        var frame = try codec.encode(.control(credential: try makeCredential()))
        // Corrupt the first token byte to a character outside base64url.
        frame[frame.startIndex + 18] = UInt8(ascii: "!")

        #expect(throws: PeerPairGrantCredentialError.invalidSignedToken) {
            try codec.decodePrefix(frame)
        }
    }

    // MARK: Truncation

    @Test func incompleteFrameReportsTheExactNextRequiredLength() throws {
        let codec = try PeerLaneHeaderCodec()
        let encoded = try codec.encode(.control(credential: try makeCredential()))

        #expect(throws: PeerLaneHeaderCodecError.incompleteFrame(requiredByteCount: 16)) {
            try codec.decodePrefix(Data())
        }
        #expect(throws: PeerLaneHeaderCodecError.incompleteFrame(requiredByteCount: 16)) {
            try codec.decodePrefix(encoded.prefix(15))
        }
        #expect(throws: PeerLaneHeaderCodecError.incompleteFrame(requiredByteCount: encoded.count)) {
            try codec.decodePrefix(encoded.dropLast())
        }
    }

    @Test func truncatedFieldInsideAWellFramedPayloadIsInvalidPayload() throws {
        let codec = try PeerLaneHeaderCodec()
        var frame = try codec.encode(
            .terminal(resourceID: try PeerResourceID("terminal:1"), cursor: nil)
        )
        // Claim a resource-ID longer than the declared payload.
        frame[frame.startIndex + 16] = 200

        #expect(throws: PeerLaneHeaderCodecError.invalidPayload) {
            try codec.decodePrefix(frame)
        }
    }

    // MARK: Malformed prefixes

    @Test func malformedPrefixAndReservedFieldsFailClosed() throws {
        let codec = try PeerLaneHeaderCodec()
        let baseline = try codec.encode(
            .terminal(resourceID: try PeerResourceID("terminal:1"), cursor: nil)
        )

        var invalidMagic = baseline
        invalidMagic[invalidMagic.startIndex] ^= 0xff
        #expect(throws: PeerLaneHeaderCodecError.invalidMagic) {
            try codec.decodePrefix(invalidMagic)
        }

        var invalidVersion = baseline
        invalidVersion[invalidVersion.startIndex + 8] = 2
        #expect(throws: PeerLaneHeaderCodecError.unsupportedVersion(2)) {
            try codec.decodePrefix(invalidVersion)
        }

        var unknownLane = baseline
        unknownLane[unknownLane.startIndex + 9] = 99
        #expect(throws: PeerLaneHeaderCodecError.unknownLane(99)) {
            try codec.decodePrefix(unknownLane)
        }

        var reservedFlags = baseline
        reservedFlags[reservedFlags.startIndex + 10] = 0x80
        #expect(throws: PeerLaneHeaderCodecError.invalidFlags(0x80)) {
            try codec.decodePrefix(reservedFlags)
        }
    }

    @Test func controlAndArtifactRejectReservedFlags() throws {
        let codec = try PeerLaneHeaderCodec()

        var control = try codec.encode(.control(credential: try makeCredential()))
        control[control.startIndex + 10] = 1
        #expect(throws: PeerLaneHeaderCodecError.invalidFlags(1)) {
            try codec.decodePrefix(control)
        }

        var artifact = try codec.encode(
            .artifact(resourceID: try PeerResourceID("a:1"), offset: 1)
        )
        artifact[artifact.startIndex + 10] = 1
        #expect(throws: PeerLaneHeaderCodecError.invalidFlags(1)) {
            try codec.decodePrefix(artifact)
        }
    }

    @Test func nonUTF8ResourceBytesAreInvalidPayload() throws {
        let codec = try PeerLaneHeaderCodec()
        var frame = try codec.encode(
            .terminal(resourceID: try PeerResourceID("terminal:1"), cursor: nil)
        )
        frame[frame.startIndex + 17] = 0xff

        #expect(throws: PeerLaneHeaderCodecError.invalidPayload) {
            try codec.decodePrefix(frame)
        }
    }

    @Test func payloadMustBeConsumedExactly() throws {
        let codec = try PeerLaneHeaderCodec()
        var frame = try codec.encode(.serverEvents(cursor: nil))
        frame[frame.startIndex + 15] = 1
        frame.append(0)

        #expect(throws: PeerLaneHeaderCodecError.invalidPayload) {
            try codec.decodePrefix(frame)
        }
    }

    // MARK: Size bounds

    @Test func declaredOversizeHeaderIsRejectedBeforeBufferingPayload() throws {
        let codec = try PeerLaneHeaderCodec(
            configuration: PeerProtocolConfiguration(
                alpn: Data("test".utf8),
                headerMagic: Data("CMUXPRT2".utf8),
                headerVersion: 1,
                maximumHeaderByteCount: 32
            )
        )
        var prefix = Data("CMUXPRT2".utf8)
        prefix.append(contentsOf: [1, 1, 0, 1, 0, 0, 1, 0])

        #expect(throws: PeerLaneHeaderCodecError.headerTooLarge(272)) {
            try codec.decodePrefix(prefix)
        }
    }

    @Test func defaultBoundRejectsAHostileDeclaredLength() throws {
        let codec = try PeerLaneHeaderCodec()
        var prefix = Data("CMUXPRT2".utf8)
        // Declared payload 0xFFFFFFFF.
        prefix.append(contentsOf: [1, 1, 0, 1, 0xff, 0xff, 0xff, 0xff])

        #expect(throws: PeerLaneHeaderCodecError.headerTooLarge(16 + 0xFFFF_FFFF)) {
            try codec.decodePrefix(prefix)
        }
    }

    @Test func encodeRejectsHeadersOverTheConfiguredLimit() throws {
        let codec = try PeerLaneHeaderCodec(
            configuration: PeerProtocolConfiguration(
                alpn: Data("test".utf8),
                headerMagic: Data("CMUXPRT2".utf8),
                headerVersion: 1,
                maximumHeaderByteCount: 32
            )
        )
        let resourceID = try PeerResourceID(String(repeating: "a", count: 32))

        #expect(throws: PeerLaneHeaderCodecError.headerTooLarge(49)) {
            try codec.encode(.terminal(resourceID: resourceID, cursor: nil))
        }
    }

    @Test func configurationMustContainTheFixedPrefix() {
        #expect(throws: PeerLaneHeaderCodecError.invalidConfiguration) {
            try PeerLaneHeaderCodec(
                configuration: PeerProtocolConfiguration(
                    alpn: Data("test".utf8),
                    headerMagic: Data("CMUXPRT2".utf8),
                    headerVersion: 1,
                    maximumHeaderByteCount: 8
                )
            )
        }
        #expect(throws: PeerLaneHeaderCodecError.invalidConfiguration) {
            try PeerLaneHeaderCodec(
                configuration: PeerProtocolConfiguration(
                    alpn: Data("test".utf8),
                    headerMagic: Data(),
                    headerVersion: 1,
                    maximumHeaderByteCount: 1_024
                )
            )
        }
    }

    // MARK: Field validation

    @Test func pairGrantTokenValidationRejectsAmbiguousValues() {
        #expect(throws: PeerPairGrantCredentialError.invalidSignedToken) {
            try PeerPairGrantCredential(token: "not-a-jws")
        }
        #expect(throws: PeerPairGrantCredentialError.invalidSignedToken) {
            try PeerPairGrantCredential(token: "e30..AA")
        }
        #expect(throws: PeerPairGrantCredentialError.invalidSignedToken) {
            try PeerPairGrantCredential(token: "a.b")
        }
        let oversized = "e30.e30." + String(repeating: "A", count: 12 * 1_024)
        #expect(throws: PeerPairGrantCredentialError.invalidSignedToken) {
            try PeerPairGrantCredential(token: oversized)
        }
    }

    @Test func resourceIDValidationRejectsAmbiguousValues() throws {
        #expect(throws: PeerResourceIDError.invalidValue) {
            try PeerResourceID("device name")
        }
        #expect(throws: PeerResourceIDError.invalidValue) {
            try PeerResourceID("")
        }
        #expect(throws: PeerResourceIDError.invalidValue) {
            try PeerResourceID(String(repeating: "a", count: 129))
        }
        #expect(try PeerResourceID(String(repeating: "a", count: 128)).value.count == 128)
        #expect(try PeerResourceID("a.B:c_d-9").value == "a.B:c_d-9")
    }
}
