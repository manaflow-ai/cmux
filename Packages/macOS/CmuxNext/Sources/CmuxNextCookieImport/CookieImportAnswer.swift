/// The person's answer on the permission card.
public nonisolated enum CookieImportAnswer: Sendable, Equatable {
    /// Allow once: this import only, never remembered.
    case allow
    /// Deny (also closing the card, Escape, or the window closing).
    case deny
    /// No answer within the card's limit; treated as Deny.
    case timedOut
}
