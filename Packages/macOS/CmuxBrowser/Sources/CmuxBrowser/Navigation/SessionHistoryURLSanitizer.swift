public import Foundation

/// Normalizes URLs for session-history persistence and replay.
///
/// Restored browser session history stores a list of URL strings. Two rules
/// govern which URLs are eligible: a URL must be non-empty and not `about:blank`,
/// and it must not be a *temporary* URL (a diff-viewer custom-scheme URL or a
/// remote loopback proxy alias) whose backing server is gone after a restart.
/// The temporary-URL classification depends on app-target types
/// (`CmuxDiffViewerURLSchemeHandler`, `RemoteLoopbackProxyAlias`), so it is
/// inverted into the injected `isTemporary` seam rather than reached for here.
public struct SessionHistoryURLSanitizer: Sendable {
    private let isTemporary: @Sendable (URL?) -> Bool

    /// Creates a sanitizer.
    ///
    /// - Parameter isTemporary: Returns `true` when a URL is a transient
    ///   session-history URL (diff viewer or remote loopback proxy alias) that
    ///   must never be persisted or replayed across restarts.
    public init(isTemporary: @escaping @Sendable (URL?) -> Bool) {
        self.isTemporary = isTemporary
    }

    /// Returns whether a URL is a transient session-history URL.
    public func isTemporarySessionHistoryURL(_ url: URL?) -> Bool {
        isTemporary(url)
    }

    /// Returns the serialized string for a URL, or `nil` when the URL is not
    /// eligible for session-history persistence.
    public func serializableSessionHistoryURLString(_ url: URL?) -> String? {
        guard let url else { return nil }
        guard !isTemporary(url) else { return nil }
        let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "about:blank" else { return nil }
        return value
    }

    /// Parses a stored history string into an eligible URL, or `nil` when the
    /// string is empty, `about:blank`, unparseable, or temporary.
    public func sanitizedSessionHistoryURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "about:blank" else { return nil }
        guard let url = URL(string: trimmed),
              !isTemporary(url) else {
            return nil
        }
        return url
    }

    /// Maps a list of stored history strings to eligible URLs, dropping any that
    /// fail `sanitizedSessionHistoryURL`.
    public func sanitizedSessionHistoryURLs(_ values: [String]) -> [URL] {
        values.compactMap { sanitizedSessionHistoryURL($0) }
    }
}
