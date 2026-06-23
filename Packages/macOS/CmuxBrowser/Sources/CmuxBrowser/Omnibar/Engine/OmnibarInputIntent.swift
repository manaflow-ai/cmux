public import Foundation

/// How the omnibar interprets a typed query: a likely URL, a likely search
/// query, or ambiguous (dotted single token that could be either).
///
/// The classification is byte-faithful to the legacy `omnibarInputIntent`: the
/// caller passes the already-resolved navigable URL (the engine stays pure and
/// performs no URL resolution itself), so a non-nil `resolvedURL` is `.urlLike`.
public enum OmnibarInputIntent: Equatable, Sendable {
    case urlLike
    case queryLike
    case ambiguous

    /// Classifies `query` given its pre-resolved navigable URL.
    ///
    /// - Parameters:
    ///   - query: The raw address-bar query (trimmed internally).
    ///   - resolvedURL: The navigable URL `query` resolves to, or `nil` when it
    ///     does not resolve to one. Resolution is performed by the caller so the
    ///     engine remains a pure value transform.
    public static func resolve(for query: String, resolvedURL: URL?) -> OmnibarInputIntent {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ambiguous }

        if resolvedURL != nil {
            return .urlLike
        }

        if trimmed.contains(" ") {
            return .queryLike
        }

        if trimmed.contains(".") {
            return .ambiguous
        }

        return .queryLike
    }
}
