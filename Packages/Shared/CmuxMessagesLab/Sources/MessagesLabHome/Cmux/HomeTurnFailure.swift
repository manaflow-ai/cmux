import Foundation

/// A Chief turn's failure line, read back out of the message the turn posted.
///
/// optchat-chief ends a failed turn's message with `(turn failed on claude: fetch failed)`
/// (`ended_turn_text` in `brain/turns.rs`), after whatever the turn said first. Every bridge
/// (iMessage too) and the auto-resume reader read that text, so it stays the message; Home draws
/// its tail as a card in plain words instead (``HomeTurnFailureRowProvider``), with the raw line
/// kept whole for Details and Copy error (Lawrence 2026-11-07: "we need better error messages in
/// the chat ui itself").
struct HomeTurnFailure: Equatable, Sendable {
    /// What the turn said before it failed (empty when it said nothing).
    let lead: String
    /// The card's sentence: what happened, in plain words.
    let title: String
    /// The failure line as optchat-chief wrote it, without its parentheses.
    let detail: String

    /// The failure at the end of `text`, or nil when `text` does not end with one.
    init?(text: String) {
        let tail = #/(?s)(?:\A|\n\n)\((turn failed(?: on [^:\n()]+(?: \(fallback for [^)\n]+\))?)?): (.+)\)\s*\z/#
        guard let match = text.firstMatch(of: tail) else { return nil }
        lead = String(text.prefix(upTo: match.range.lowerBound)).trimmingCharacters(in: .whitespacesAndNewlines)
        let error = String(match.output.2)
        detail = "\(match.output.1): \(error)"
        title = Self.title(error)
    }

    /// The sentence for a harness error: a usage limit, a sign-in, the network, the model service,
    /// else the general one. The raw error says the rest under Details.
    private static func title(_ error: String) -> String {
        let text = error.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("quota", "credit balance", "usage limit", "rate limit")
            || (text.contains("limit") && has("hit your", "reached your", "weekly", "monthly", "resets")) {
            return CmuxStrings.turnFailureLimit
        }
        if has("not logged in", "log in", "/login", "unauthorized", "invalid api key", "authentication") {
            return CmuxStrings.turnFailureSignedOut
        }
        if has("fetch failed", "econn", "enotfound", "etimedout", "network", "timed out", "socket hang up", "connection") {
            return CmuxStrings.turnFailureNetwork
        }
        if has("internal error", "internal server error", "overloaded", "api error", "service unavailable", "bad gateway") {
            return CmuxStrings.turnFailureService
        }
        return CmuxStrings.turnFailureGeneric
    }
}
