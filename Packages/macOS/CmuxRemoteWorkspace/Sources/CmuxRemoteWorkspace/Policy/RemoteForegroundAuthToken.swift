import Foundation

/// Normalizes a remote workspace's foreground authentication token.
///
/// Pure value/decision helper extracted from the legacy static
/// `Workspace.normalizedForegroundAuthToken(_:)`. Trims surrounding whitespace
/// and collapses an empty or whitespace-only token to `nil` so the workspace
/// can compare tokens and gate "foreground authentication ready" handling on a
/// canonical value. Byte-faithful to the legacy normalization.
public struct RemoteForegroundAuthToken: Sendable {
    /// Creates the normalizer.
    public init() {}

    /// The trimmed token, or `nil` when `token` is `nil`, empty, or only
    /// whitespace.
    public func normalized(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
