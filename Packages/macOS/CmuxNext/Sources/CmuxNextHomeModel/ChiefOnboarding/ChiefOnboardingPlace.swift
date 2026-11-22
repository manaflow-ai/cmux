/// What a Chief chat does with Meet Chief (``ChiefOnboarding/place(chatAt:shownAt:otherChiefs:)``).
public enum ChiefOnboardingPlace: Equatable, Sendable {
    /// The chat shows the card.
    case shows
    /// The person sent a message while it showed: it ends for good.
    case ends
    /// The chat shows no card.
    case hidden
}
