import Foundation
import Testing
@testable import CmuxTerminalRenderProtocol

@Suite
struct TerminalRenderFrameMetadataCodecTests {
    private let fixture = TerminalRenderProtocolTestFixture()
    private let codec = TerminalRenderFrameMetadataCodec()

    @Test
    func roundTripsEveryFieldAndSupportedFormat() throws {
        for pixelFormat in TerminalRenderPixelFormat.allCases {
            for colorSpace in TerminalRenderColorSpace.allCases {
                let damage = try TerminalRenderDamageBounds(
                    x: 12,
                    y: 34,
                    width: 500,
                    height: 300
                )
                let metadata = try fixture.makeMetadata(
                    pixelFormat: pixelFormat,
                    colorSpace: colorSpace,
                    damageBounds: damage
                )
                let encoded = codec.encode(metadata)

                #expect(encoded.count == TerminalRenderFrameProtocol.metadataLength)
                #expect(try codec.decode(encoded) == metadata)
            }
        }
    }

    @Test
    func roundTripsFullFrameDamageMarker() throws {
        let metadata = try fixture.makeMetadata(damageBounds: nil)
        #expect(try codec.decode(codec.encode(metadata)) == metadata)
    }

    @Test
    func roundTripsProducerCompletedFramesWithoutASharedEvent() throws {
        let metadata = try fixture.makeMetadata(producerCompleted: true)
        #expect(try codec.decode(codec.encode(metadata)) == metadata)
    }

    @Test
    func rejectsWrongLengthMagicVersionFlagsAndReservedBytes() throws {
        let valid = codec.encode(try fixture.makeMetadata())

        #expect(throws: TerminalRenderFrameProtocolError.invalidWireLength) {
            try codec.decode(valid.dropLast())
        }

        var badMagic = valid
        badMagic[0] ^= 0xFF
        #expect(throws: TerminalRenderFrameProtocolError.invalidWireMagic) {
            try codec.decode(badMagic)
        }

        var badVersion = valid
        badVersion[4] = 0
        badVersion[5] = 3
        #expect(throws: TerminalRenderFrameProtocolError.unsupportedWireVersion(3)) {
            try codec.decode(badVersion)
        }

        var badFlags = valid
        badFlags[7] = 0x80
        #expect(throws: TerminalRenderFrameProtocolError.unsupportedWireFlags(0x80)) {
            try codec.decode(badFlags)
        }

        var badReserved = valid
        badReserved[159] = 1
        #expect(throws: TerminalRenderFrameProtocolError.nonzeroReservedBytes) {
            try codec.decode(badReserved)
        }
    }

    @Test
    func rejectsUnsupportedFormatColorSpaceAndZeroFence() throws {
        let valid = codec.encode(try fixture.makeMetadata())

        var badFormat = valid
        badFormat.replaceSubrange(104..<108, with: [0, 0, 0, 0x7F])
        #expect(throws: TerminalRenderFrameProtocolError.unsupportedPixelFormat(0x7F)) {
            try codec.decode(badFormat)
        }

        var badColorSpace = valid
        badColorSpace.replaceSubrange(108..<112, with: [0, 0, 0, 0x7F])
        #expect(throws: TerminalRenderFrameProtocolError.unsupportedColorSpace(0x7F)) {
            try codec.decode(badColorSpace)
        }

        var zeroFence = valid
        zeroFence.replaceSubrange(128..<136, with: repeatElement(UInt8(0), count: 8))
        #expect(throws: TerminalRenderFrameProtocolError.invalidCompletionFence) {
            try codec.decode(zeroFence)
        }
    }

    @Test
    func rejectsNoncanonicalProducerCompletedPayload() throws {
        var encoded = codec.encode(try fixture.makeMetadata(producerCompleted: true))
        encoded[127] = 1
        #expect(throws: TerminalRenderFrameProtocolError.nonzeroReservedBytes) {
            try codec.decode(encoded)
        }
    }

    @Test
    func rejectsInvalidDamageEncodingBeforeAllocation() throws {
        let valid = codec.encode(try fixture.makeMetadata())

        var unflaggedDamage = valid
        unflaggedDamage[139] = 1
        #expect(throws: TerminalRenderFrameProtocolError.nonzeroReservedBytes) {
            try codec.decode(unflaggedDamage)
        }

        var emptyFlaggedDamage = valid
        emptyFlaggedDamage[7] = 1
        #expect(throws: TerminalRenderFrameProtocolError.invalidDamageBounds) {
            try codec.decode(emptyFlaggedDamage)
        }

        let damage = try TerminalRenderDamageBounds(x: 1_599, y: 899, width: 1, height: 1)
        var outOfBounds = codec.encode(try fixture.makeMetadata(damageBounds: damage))
        outOfBounds.replaceSubrange(144..<148, with: [0, 0, 0, 2])
        #expect(throws: TerminalRenderFrameProtocolError.invalidDamageBounds) {
            try codec.decode(outOfBounds)
        }
    }

    @Test
    func constructorsEnforceDimensionAreaDamageAndEndpointBounds() throws {
        #expect(throws: TerminalRenderFrameProtocolError.invalidDimensions) {
            try fixture.makeMetadata(width: 0)
        }
        #expect(throws: TerminalRenderFrameProtocolError.invalidDimensions) {
            try fixture.makeMetadata(width: TerminalRenderFrameProtocol.maximumDimension + 1)
        }
        #expect(throws: TerminalRenderFrameProtocolError.invalidDimensions) {
            try fixture.makeMetadata(width: 16_384, height: 16_384)
        }
        let overflowingDamage = try TerminalRenderDamageBounds(
            x: .max,
            y: 0,
            width: 2,
            height: 1
        )
        #expect(throws: TerminalRenderFrameProtocolError.invalidDamageBounds) {
            try fixture.makeMetadata(damageBounds: overflowingDamage)
        }
        #expect(throws: TerminalRenderFrameProtocolError.invalidServiceName) {
            try TerminalRenderFrameEndpoint(
                serviceName: "bad\0name",
                capability: Data(repeating: 1, count: TerminalRenderFrameProtocol.capabilityLength)
            )
        }
        #expect(throws: TerminalRenderFrameProtocolError.invalidCapabilityLength) {
            try TerminalRenderFrameEndpoint(serviceName: "valid", capability: Data(repeating: 1, count: 31))
        }
        #expect(throws: TerminalRenderFrameProtocolError.invalidWorkerIdentity) {
            try TerminalRenderWorkerIdentity(
                processID: 0,
                effectiveUserID: 0,
                processInstanceToken: TerminalRenderProcessInstanceToken(
                    startTimeSeconds: 1,
                    startTimeMicroseconds: 2
                )
            )
        }
    }

    @Test
    func endpointCodableRoundTripCannotBypassCapabilityValidation() throws {
        let endpoint = try TerminalRenderFrameEndpoint(
            serviceName: "dev.cmux.render-test",
            capability: Data(
                repeating: 0xA5,
                count: TerminalRenderFrameProtocol.capabilityLength
            )
        )
        let encoded = try PropertyListEncoder().encode(endpoint)
        #expect(try PropertyListDecoder().decode(
            TerminalRenderFrameEndpoint.self,
            from: encoded
        ) == endpoint)

        let invalidPropertyList: [String: Any] = [
            "serviceName": "dev.cmux.render-test",
            "capability": Data(repeating: 0, count: 1),
        ]
        let invalidData = try PropertyListSerialization.data(
            fromPropertyList: invalidPropertyList,
            format: .binary,
            options: 0
        )
        #expect(throws: TerminalRenderFrameProtocolError.invalidCapabilityLength) {
            try PropertyListDecoder().decode(
                TerminalRenderFrameEndpoint.self,
                from: invalidData
            )
        }
    }
}
