/// Binary framing failures for the single-phase admission acknowledgement.
public enum PeerAdmissionAckCodecError: Error, Equatable, Sendable {
    /// More bytes are needed before the complete ack can be decoded.
    case incompleteFrame(requiredByteCount: Int)

    /// The frame did not begin with the cmux admission marker.
    case invalidMagic

    /// The frame version is unsupported.
    case unsupportedVersion(UInt8)

    /// The status discriminator is unknown.
    case invalidStatus(UInt8)

    /// Reserved flag bits were set for the frame's status.
    case invalidFlags(UInt8)

    /// An accepted frame carried a nonzero denial reason.
    case invalidAcceptedReason(UInt8)

    /// A denied frame carried a reason outside the bounded enum.
    case unknownDenialReason(UInt8)

    /// The denial message exceeds the bounded maximum.
    case messageTooLong(Int)

    /// The payload length or content violates the binary contract.
    case invalidPayload
}
