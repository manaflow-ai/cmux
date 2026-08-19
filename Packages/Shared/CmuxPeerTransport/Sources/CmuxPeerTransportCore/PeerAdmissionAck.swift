/// The host's single admission acknowledgement on the control lane.
///
/// v3 admission is single-phase: the host verifies the pair grant carried by
/// the control lane header and answers exactly one frame. Denial closes the
/// connection. The old two-phase NAT-authorization barrier (accepted-pending,
/// client-ready, server-ready) is deleted by design.
public enum PeerAdmissionAck: Equatable, Sendable {
    /// The grant verified; application lanes may open immediately.
    ///
    /// `grantExpiryUnixSeconds` optionally tells the client when the admitted
    /// grant expires so it can refresh before the host's next revalidation.
    case accepted(grantExpiryUnixSeconds: UInt64?)

    /// Admission failed with a bounded reason and a bounded diagnostic message.
    ///
    /// The message is a non-sensitive, non-user-facing protocol diagnostic.
    case denied(reason: PeerAdmissionDenialReason, message: String)
}

/// A bounded, non-sensitive admission denial reason.
public enum PeerAdmissionDenialReason: UInt8, CaseIterable, Equatable, Sendable {
    /// The host declined without a more specific classification.
    case unspecified = 0

    /// The credential was malformed or its signature did not verify.
    case credentialInvalid = 1

    /// The grant verified but is past its expiry.
    case credentialExpired = 2

    /// The grant was revoked (broker revalidation said no).
    case credentialRevoked = 3

    /// The grant is not bound to this device and endpoint pair.
    case bindingMismatch = 4

    /// The host is at connection capacity; retry later.
    case busy = 5
}

/// A decoded admission ack and the number of prefix bytes it consumed.
public struct PeerDecodedAdmissionAck: Equatable, Sendable {
    /// The validated acknowledgement.
    public let ack: PeerAdmissionAck

    /// The byte offset at which following control bytes begin.
    public let consumedByteCount: Int

    /// Creates a decoded-ack result.
    ///
    /// - Parameters:
    ///   - ack: The validated acknowledgement.
    ///   - consumedByteCount: The exact number of framing bytes consumed.
    public init(ack: PeerAdmissionAck, consumedByteCount: Int) {
        self.ack = ack
        self.consumedByteCount = consumedByteCount
    }
}
