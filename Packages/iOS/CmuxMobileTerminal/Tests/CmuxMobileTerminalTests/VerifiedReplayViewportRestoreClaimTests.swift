import Testing

@testable import CmuxMobileTerminal

@Suite("Verified replay viewport restore claim")
struct VerifiedReplayViewportRestoreClaimTests {
    @Test("a matching ticket with unchanged intent claims the restore")
    func claims() {
        #expect(
            VerifiedReplayViewportRestoreClaim.decide(
                activeTicket: 7,
                operationID: 7,
                interactionGeneration: 3,
                capturedInteractionGeneration: 3
            ) == .claimed
        )
    }

    @Test("intent advanced after capture reports a late user interaction")
    func staleInteraction() {
        #expect(
            VerifiedReplayViewportRestoreClaim.decide(
                activeTicket: 7,
                operationID: 7,
                interactionGeneration: 4,
                capturedInteractionGeneration: 3
            ) == .staleInteraction
        )
    }

    @Test("a deadline-revoked or superseded ticket is not blamed on the user")
    func ticketRevoked() {
        #expect(
            VerifiedReplayViewportRestoreClaim.decide(
                activeTicket: nil,
                operationID: 7,
                interactionGeneration: 3,
                capturedInteractionGeneration: 3
            ) == .ticketRevoked
        )
        #expect(
            VerifiedReplayViewportRestoreClaim.decide(
                activeTicket: 9,
                operationID: 7,
                interactionGeneration: 3,
                capturedInteractionGeneration: 3
            ) == .ticketRevoked
        )
    }

    @Test("a real user interaction outranks ticket revocation as the cause")
    func staleInteractionOutranksRevokedTicket() {
        #expect(
            VerifiedReplayViewportRestoreClaim.decide(
                activeTicket: nil,
                operationID: 7,
                interactionGeneration: 4,
                capturedInteractionGeneration: 3
            ) == .staleInteraction
        )
    }
}
