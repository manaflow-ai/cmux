import Foundation

extension BrowserImportScope {
    /// The outcome of parsing a `browser.import` `scope` request token.
    ///
    /// Distinguishes an absent-or-empty token (the caller treats this as the
    /// "no explicit scope" case) from an unrecognized token (a hard
    /// `invalid_params` error) from a successfully resolved scope, so the control
    /// witness re-emits the exact same three legacy categories.
    public enum RawTokenResolution: Sendable, Equatable {
        /// The token was missing or empty after trimming.
        case empty
        /// The token was present but matched no known scope alias.
        case invalid
        /// The token resolved to a scope.
        case scope(BrowserImportScope)
    }

    /// Resolves a `browser.import` `scope` request token to a scope.
    ///
    /// Trims whitespace/newlines and lowercases the token, then matches the same
    /// alias set the `controlBrowserImportDialog` witness previously matched
    /// inline (`cookie`/`cookies`/`cookiesonly`/... → ``cookiesOnly``,
    /// `history`/... → ``historyOnly``, `cookiesandhistory`/... /`all-basic` →
    /// ``cookiesAndHistory``, `everything`/`all` → ``everything``). An empty
    /// trimmed token yields ``RawTokenResolution/empty``; any other unmatched
    /// token yields ``RawTokenResolution/invalid``. Byte-identical to the former
    /// inline `switch`.
    /// - Parameter rawToken: the raw `scope` parameter string, or `nil` when the
    ///   key was present but not a string.
    /// - Returns: the resolution category.
    public static func from(rawToken: String?) -> RawTokenResolution {
        guard let raw = rawToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !raw.isEmpty else {
            return .empty
        }
        switch raw {
        case "cookie", "cookies", "cookiesonly", "cookies_only", "cookies-only":
            return .scope(.cookiesOnly)
        case "history", "historyonly", "history_only", "history-only":
            return .scope(.historyOnly)
        case "cookiesandhistory", "cookies_and_history", "cookies-and-history", "all-basic":
            return .scope(.cookiesAndHistory)
        case "everything", "all":
            return .scope(.everything)
        default:
            return .invalid
        }
    }
}
