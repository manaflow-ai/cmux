public import Foundation

/// Encodes and decodes the host's single-phase admission acknowledgement.
///
/// Wire layout, all integers big-endian:
/// `magic(8) | version(1) | status(1) | flags(1) | reason(1) | payloadByteCount(2) | payload`.
/// An accepted payload is empty or one UInt64 grant expiry (flag bit 0);
/// a denied payload is the bounded UTF-8 diagnostic message.
public struct PeerAdmissionAckCodec: Sendable {
    /// The exact byte count of the fixed frame prefix.
    public static let fixedPrefixByteCount = 14

    /// The largest denial message, in UTF-8 bytes.
    public static let maximumDeniedMessageByteCount = 256

    private static let magic = Data("CMXPACK2".utf8)
    private static let version: UInt8 = 1
    private static let acceptedStatus: UInt8 = 1
    private static let deniedStatus: UInt8 = 2
    private static let grantExpiryPresentFlag: UInt8 = 1
    private static let grantExpiryByteCount = 8

    /// The declared payload shape, fully validated from the fixed prefix
    /// before any payload bytes are required.
    private enum FrameShape {
        case accepted(expiryPresent: Bool)
        case denied(PeerAdmissionDenialReason)
    }

    /// Creates an admission-ack codec.
    public init() {}

    /// Encodes one acknowledgement into its complete binary frame.
    ///
    /// - Parameter ack: The host's admission decision.
    /// - Returns: The binary frame bytes.
    /// - Throws: ``PeerAdmissionAckCodecError/messageTooLong(_:)`` for an
    ///   over-long denial message.
    public func encode(_ ack: PeerAdmissionAck) throws -> Data {
        let status: UInt8
        let flags: UInt8
        let reasonCode: UInt8
        var payload = PeerBinaryWriter()

        switch ack {
        case let .accepted(grantExpiryUnixSeconds):
            status = Self.acceptedStatus
            reasonCode = 0
            if let grantExpiryUnixSeconds {
                flags = Self.grantExpiryPresentFlag
                payload.append(grantExpiryUnixSeconds)
            } else {
                flags = 0
            }

        case let .denied(reason, message):
            status = Self.deniedStatus
            flags = 0
            reasonCode = reason.rawValue
            let bytes = Data(message.utf8)
            guard bytes.count <= Self.maximumDeniedMessageByteCount else {
                throw PeerAdmissionAckCodecError.messageTooLong(bytes.count)
            }
            payload.append(contentsOf: bytes)
        }

        var frame = PeerBinaryWriter(capacity: Self.fixedPrefixByteCount + payload.data.count)
        frame.append(contentsOf: Self.magic)
        frame.append(Self.version)
        frame.append(status)
        frame.append(flags)
        frame.append(reasonCode)
        // Bounded above by the message and expiry limits, so UInt16 always fits.
        frame.append(UInt16(payload.data.count))
        frame.append(contentsOf: payload.data)
        return frame.data
    }

    /// Decodes one ack prefix while preserving any following control bytes.
    ///
    /// - Parameter data: Bytes beginning at the start of the host's response.
    /// - Returns: The acknowledgement and exact byte count consumed from `data`.
    /// - Throws: ``PeerAdmissionAckCodecError`` for malformed input.
    public func decodePrefix(_ data: Data) throws -> PeerDecodedAdmissionAck {
        do {
            return try decodeValidatedPrefix(data)
        } catch is PeerBinaryCursor.Failure {
            // Truncated or non-UTF-8 field inside a well-framed payload.
            throw PeerAdmissionAckCodecError.invalidPayload
        }
    }

    private func decodeValidatedPrefix(_ data: Data) throws -> PeerDecodedAdmissionAck {
        guard data.count >= Self.fixedPrefixByteCount else {
            throw PeerAdmissionAckCodecError.incompleteFrame(
                requiredByteCount: Self.fixedPrefixByteCount
            )
        }

        var prefix = PeerBinaryCursor(data: data.prefix(Self.fixedPrefixByteCount))
        guard try prefix.readData(byteCount: Self.magic.count) == Self.magic else {
            throw PeerAdmissionAckCodecError.invalidMagic
        }
        let version = try prefix.readUInt8()
        guard version == Self.version else {
            throw PeerAdmissionAckCodecError.unsupportedVersion(version)
        }
        let status = try prefix.readUInt8()
        let flags = try prefix.readUInt8()
        let reasonCode = try prefix.readUInt8()
        let payloadByteCount = Int(try prefix.readUInt16())

        let shape = try validateShape(
            status: status,
            flags: flags,
            reasonCode: reasonCode,
            payloadByteCount: payloadByteCount
        )

        let totalByteCount = Self.fixedPrefixByteCount + payloadByteCount
        guard data.count >= totalByteCount else {
            throw PeerAdmissionAckCodecError.incompleteFrame(requiredByteCount: totalByteCount)
        }

        let payloadStart = data.index(data.startIndex, offsetBy: Self.fixedPrefixByteCount)
        let payloadEnd = data.index(payloadStart, offsetBy: payloadByteCount)
        var payload = PeerBinaryCursor(data: data[payloadStart ..< payloadEnd])

        let ack: PeerAdmissionAck
        switch shape {
        case let .accepted(expiryPresent):
            if expiryPresent {
                ack = .accepted(grantExpiryUnixSeconds: try payload.readUInt64())
            } else {
                ack = .accepted(grantExpiryUnixSeconds: nil)
            }
        case let .denied(reason):
            let message = try payload.readString(byteCount: payloadByteCount)
            ack = .denied(reason: reason, message: message)
        }
        guard payload.remainingByteCount == 0 else {
            throw PeerAdmissionAckCodecError.invalidPayload
        }
        return PeerDecodedAdmissionAck(ack: ack, consumedByteCount: totalByteCount)
    }

    private func validateShape(
        status: UInt8,
        flags: UInt8,
        reasonCode: UInt8,
        payloadByteCount: Int
    ) throws -> FrameShape {
        switch status {
        case Self.acceptedStatus:
            guard flags & ~Self.grantExpiryPresentFlag == 0 else {
                throw PeerAdmissionAckCodecError.invalidFlags(flags)
            }
            guard reasonCode == 0 else {
                throw PeerAdmissionAckCodecError.invalidAcceptedReason(reasonCode)
            }
            let expiryPresent = flags & Self.grantExpiryPresentFlag != 0
            let expectedByteCount = expiryPresent ? Self.grantExpiryByteCount : 0
            guard payloadByteCount == expectedByteCount else {
                throw PeerAdmissionAckCodecError.invalidPayload
            }
            return .accepted(expiryPresent: expiryPresent)

        case Self.deniedStatus:
            guard flags == 0 else {
                throw PeerAdmissionAckCodecError.invalidFlags(flags)
            }
            guard let reason = PeerAdmissionDenialReason(rawValue: reasonCode) else {
                throw PeerAdmissionAckCodecError.unknownDenialReason(reasonCode)
            }
            guard payloadByteCount <= Self.maximumDeniedMessageByteCount else {
                throw PeerAdmissionAckCodecError.messageTooLong(payloadByteCount)
            }
            return .denied(reason)

        default:
            throw PeerAdmissionAckCodecError.invalidStatus(status)
        }
    }
}
