import Foundation

/// The breadth of data a browser import copies into a cmux browser profile.
///
/// The scope determines whether cookies, history, or both are read from the
/// source browser, and whether the user requested the (not yet implemented)
/// bookmarks/settings/extensions tier via ``everything``.
public enum BrowserImportScope: String, CaseIterable, Identifiable, Sendable {
    /// Import only cookies from the source browser.
    case cookiesOnly
    /// Import only browsing history from the source browser.
    case historyOnly
    /// Import both cookies and browsing history.
    case cookiesAndHistory
    /// Import everything cmux can currently read, plus a warning for the data
    /// types (bookmarks, settings, extensions) that are not yet supported.
    case everything

    /// Stable identifier matching the raw string value.
    public var id: String { rawValue }

    /// Localized, user-facing label for the scope.
    public var displayName: String {
        switch self {
        case .cookiesOnly:
            return String(localized: "browser.import.scope.cookiesOnly", defaultValue: "Cookies only")
        case .historyOnly:
            return String(localized: "browser.import.scope.historyOnly", defaultValue: "History only")
        case .cookiesAndHistory:
            return String(localized: "browser.import.scope.cookiesAndHistory", defaultValue: "Cookies + history")
        case .everything:
            return String(localized: "browser.import.scope.everything", defaultValue: "Everything")
        }
    }

    /// Whether this scope copies cookies.
    public var includesCookies: Bool {
        switch self {
        case .cookiesOnly, .cookiesAndHistory, .everything:
            return true
        case .historyOnly:
            return false
        }
    }

    /// Whether this scope copies browsing history.
    public var includesHistory: Bool {
        switch self {
        case .cookiesOnly:
            return false
        case .historyOnly, .cookiesAndHistory, .everything:
            return true
        }
    }

    /// Resolves a scope from the import wizard's three checkbox states.
    ///
    /// - Parameters:
    ///   - includeCookies: Whether the cookies checkbox is on.
    ///   - includeHistory: Whether the history checkbox is on.
    ///   - includeAdditionalData: Whether the additional-data checkbox is on; if
    ///     set, the result is always ``everything``.
    /// - Returns: The resolved scope, or `nil` when nothing is selected.
    public static func fromSelection(
        includeCookies: Bool,
        includeHistory: Bool,
        includeAdditionalData: Bool
    ) -> BrowserImportScope? {
        if includeAdditionalData {
            return .everything
        }
        guard includeCookies || includeHistory else { return nil }
        if includeCookies && includeHistory {
            return .cookiesAndHistory
        }
        if includeCookies {
            return .cookiesOnly
        }
        return .historyOnly
    }
}
