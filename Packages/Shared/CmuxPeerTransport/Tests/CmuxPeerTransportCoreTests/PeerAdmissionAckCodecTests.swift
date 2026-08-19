import Foundation
import Testing

@testable import CmuxPeerTransportCore

@Suite struct PeerAdmissionAckCodecTests {
    @Test(arguments: [
        PeerAdmissionAck.accepted(grantExpiryUnixSeconds: nil),
        PeerAdmissionAck.accepted(grantExpiryUnixSeconds: 1_766_000_000),
        PeerAdmissionAck.accepted(grantExpiryUnixSeconds: .max),
        PeerAdmissionAck.denied(reason: .unspecified, message: ""),
        PeerAdmissionAck.denied(reason: .credentialInvalid, message: "bad signature"),
        PeerAdmissionAck.denied(reason: .credentialExpired, message: "expired"),
        PeerAdmissionAck.denied(reason: .credentialRevoked, message: "revoked"),
        PeerAdmissionAck.denied(reason: .bindingMismatch, message: "wrong endpoint"),
        PeerAdmissionAck.denied(reason: .busy, message: "at capacity"),
    ])
    func ackRoundTripsWithoutConsumingFollowingBytes(_ ack: PeerAdmissionAck) throws {
        let codec = PeerAdmissionAckCodec()
        let encoded = try codec.encode(ack)
        let followingBytes = Data([0xca, 0xfe])

        let decoded = try codec.decodePrefix(encoded + followingBytes)

        #expect(decoded.ack == ack)
        #expect(decoded.consumedByteCount == encoded.count)
        #expect((encoded + followingBytes).dropFirst(decoded.consumedByteCount) == followingBytes)
    }

    @Test func maximumLengthMessageRoundTrips() throws {
        let codec = PeerAdmissionAckCodec()
        let message = String(
            repeating: "x",
            count: PeerAdmissionAckCodec.maximumDeniedMessageByteCount
        )
        let ack = PeerAdmissionAck.denied(reason: .unspecified, message: message)

        #expect(try codec.decodePrefix(codec.encode(ack)).ack == ack)
    }

    @Test func incompleteFrameReportsTheExactNextRequiredLength() throws {
        let codec = PeerAdmissionAckCodec()
        let encoded = try codec.encode(.denied(reason: .busy, message: "nope"))

        #expect(throws: PeerAdmissionAckCodecError.incompleteFrame(requiredByteCount: 14)) {
            try codec.decodePrefix(Data(repeating: 0, count: 13))
        }
        #expect(throws: PeerAdmissionAckCodecError.incompleteFrame(requiredByteCount: encoded.count)) {
            try codec.decodePrefix(encoded.dropLast())
        }
    }

    @Test func malformedPrefixFailsClosed() throws {
        let codec = PeerAdmissionAckCodec()
        let baseline = try codec.encode(.accepted(grantExpiryUnixSeconds: nil))

        var invalidMagic = baseline
        invalidMagic[invalidMagic.startIndex] ^= 0xff
        #expect(throws: PeerAdmissionAckCodecError.invalidMagic) {
            try codec.decodePrefix(invalidMagic)
        }

        var invalidVersion = baseline
        invalidVersion[invalidVersion.startIndex + 8] = 2
        #expect(throws: PeerAdmissionAckCodecError.unsupportedVersion(2)) {
            try codec.decodePrefix(invalidVersion)
        }

        for status in [UInt8(0), UInt8(3), UInt8(0xff)] {
            var invalidStatus = baseline
            invalidStatus[invalidStatus.startIndex + 9] = status
            #expect(throws: PeerAdmissionAckCodecError.invalidStatus(status)) {
                try codec.decodePrefix(invalidStatus)
            }
        }
    }

    @Test func acceptedRejectsReservedFlagsAndNonzeroReason() throws {
        let codec = PeerAdmissionAckCodec()
        let baseline = try codec.encode(.accepted(grantExpiryUnixSeconds: nil))

        var reservedFlags = baseline
        reservedFlags[reservedFlags.startIndex + 10] = 0x02
        #expect(throws: PeerAdmissionAckCodecError.invalidFlags(0x02)) {
            try codec.decodePrefix(reservedFlags)
        }

        var nonzeroReason = baseline
        nonzeroReason[nonzeroReason.startIndex + 11] = 1
        #expect(throws: PeerAdmissionAckCodecError.invalidAcceptedReason(1)) {
            try codec.decodePrefix(nonzeroReason)
        }
    }

    @Test func acceptedPayloadShapeMustMatchTheExpiryFlag() throws {
        let codec = PeerAdmissionAckCodec()

        // Expiry flag set, but no payload declared.
        var flagWithoutPayload = try codec.encode(.accepted(grantExpiryUnixSeconds: nil))
        flagWithoutPayload[flagWithoutPayload.startIndex + 10] = 1
        #expect(throws: PeerAdmissionAckCodecError.invalidPayload) {
            try codec.decodePrefix(flagWithoutPayload)
        }

        // Payload declared, but the expiry flag cleared.
        var payloadWithoutFlag = try codec.encode(.accepted(grantExpiryUnixSeconds: 7))
        payloadWithoutFlag[payloadWithoutFlag.startIndex + 10] = 0
        #expect(throws: PeerAdmissionAckCodecError.invalidPayload) {
            try codec.decodePrefix(payloadWithoutFlag)
        }
    }

    @Test func deniedRejectsFlagsUnknownReasonsAndNonUTF8Messages() throws {
        let codec = PeerAdmissionAckCodec()
        let baseline = try codec.encode(.denied(reason: .busy, message: "x"))

        var flagged = baseline
        flagged[flagged.startIndex + 10] = 1
        #expect(throws: PeerAdmissionAckCodecError.invalidFlags(1)) {
            try codec.decodePrefix(flagged)
        }

        var unknownReason = baseline
        unknownReason[unknownReason.startIndex + 11] = 99
        #expect(throws: PeerAdmissionAckCodecError.unknownDenialReason(99)) {
            try codec.decodePrefix(unknownReason)
        }

        var nonUTF8 = baseline
        nonUTF8[nonUTF8.startIndex + 14] = 0xff
        #expect(throws: PeerAdmissionAckCodecError.invalidPayload) {
            try codec.decodePrefix(nonUTF8)
        }
    }

    @Test func oversizedMessagesAreRejectedOnEncodeAndBeforeBufferingOnDecode() throws {
        let codec = PeerAdmissionAckCodec()
        let overLimit = PeerAdmissionAckCodec.maximumDeniedMessageByteCount + 1

        #expect(throws: PeerAdmissionAckCodecError.messageTooLong(overLimit)) {
            try codec.encode(
                .denied(reason: .unspecified, message: String(repeating: "x", count: overLimit))
            )
        }

        // A hostile declared length is rejected from the prefix alone, before
        // any payload bytes arrive.
        var prefix = Data("CMXPACK2".utf8)
        prefix.append(contentsOf: [1, 2, 0, 0, 0x01, 0x2c])
        #expect(prefix.count == PeerAdmissionAckCodec.fixedPrefixByteCount)
        #expect(throws: PeerAdmissionAckCodecError.messageTooLong(300)) {
            try codec.decodePrefix(prefix)
        }
    }

    @Test func everyDenialReasonHasAStableWireCode() {
        // The raw values are the wire contract; reordering the enum is a break.
        #expect(PeerAdmissionDenialReason.unspecified.rawValue == 0)
        #expect(PeerAdmissionDenialReason.credentialInvalid.rawValue == 1)
        #expect(PeerAdmissionDenialReason.credentialExpired.rawValue == 2)
        #expect(PeerAdmissionDenialReason.credentialRevoked.rawValue == 3)
        #expect(PeerAdmissionDenialReason.bindingMismatch.rawValue == 4)
        #expect(PeerAdmissionDenialReason.busy.rawValue == 5)
        #expect(PeerAdmissionDenialReason.allCases.count == 6)
    }
}
