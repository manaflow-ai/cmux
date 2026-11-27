/// cmux (user 2026-11-05, msg 23140): how close a reply's root may be for the reply to show no quote of it. The Chief
/// answers several of my messages in a row, each in its thread; a quote of a root a few messages up repeated what was
/// in view right above it. Further up, the quote still says what the reply answers.
struct ThreadQuoteNearby {
    /// The messages right above a reply (not counting the Chief's agent asides) its root may be among.
    static let messages = 4
}
