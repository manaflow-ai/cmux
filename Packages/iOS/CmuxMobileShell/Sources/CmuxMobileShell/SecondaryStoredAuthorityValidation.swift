import CmuxMobilePairedMac

enum SecondaryStoredAuthorityValidation: Sendable {
    case cached
    case store
}

enum SecondaryStoredAuthorityRead {
    case authorized(MobilePairedMac)
    case revoked
    case transientFailure
}

enum SecondaryPromotionOutcome {
    case promoted
    case unavailable
    case transientFailure
}
