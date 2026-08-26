/// Why a queued anchor restore did or did not claim its restore ticket.
///
/// The distinction matters for diagnosis: `staleInteraction` means the user
/// really scrolled or typed after the anchor was captured, so standing down
/// preserves their intent, while `ticketRevoked` means the deadline pump or a
/// superseding restore revoked the ticket with no user involvement, so
/// standing down is a give-up under load. Logging the two identically hid
/// every deadline give-up behind a user-interaction label.
enum VerifiedReplayViewportRestoreClaim: Equatable, Sendable {
    case claimed
    case staleInteraction
    case ticketRevoked

    /// Decides the claim outcome for one queued restore block. A stale
    /// interaction outranks a revoked ticket in the reported cause: when both
    /// hold, the user-visible truth is that their newer gesture won.
    static func decide(
        activeTicket: UInt64?,
        operationID: UInt64,
        interactionGeneration: UInt64,
        capturedInteractionGeneration: UInt64
    ) -> Self {
        if interactionGeneration != capturedInteractionGeneration {
            return .staleInteraction
        }
        if activeTicket != operationID {
            return .ticketRevoked
        }
        return .claimed
    }
}
