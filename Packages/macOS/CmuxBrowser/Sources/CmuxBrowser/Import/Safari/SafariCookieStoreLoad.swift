public import Foundation

/// What ``SafariCookieStoreReader/load(for:)`` found for one Safari source profile.
public enum SafariCookieStoreLoad: Equatable, Sendable {
    /// The store at `url` was read; `data` is what the reader returned for it.
    /// The default reader returns the store through its last page and leaves
    /// out the trailer after it, which the parser ignores.
    case loaded(url: URL, data: Data)
    /// The store at `url` holds more page data than the reader's limit, so it was not loaded.
    case tooLarge(url: URL)
    /// No candidate store exists for the profile.
    case missing
    /// A store exists at `url` but macOS refused to let cmux read it; `cause`
    /// says why and so which recovery step applies.
    case accessDenied(url: URL, cause: SafariCookieStoreAccessDenial)
    /// A store exists at `url` but could not be read for another reason.
    case unreadable(url: URL)
}
