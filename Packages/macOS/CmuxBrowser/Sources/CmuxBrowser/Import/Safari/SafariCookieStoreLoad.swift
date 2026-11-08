public import Foundation

/// What ``SafariCookieStoreReader/load(for:)`` found for one Safari source profile.
public enum SafariCookieStoreLoad: Equatable, Sendable {
    /// The store at `url` was read; `data` is its full contents.
    case loaded(url: URL, data: Data)
    /// No candidate store exists for the profile.
    case missing
    /// A store exists at `url` but macOS refused to let cmux read it; `cause`
    /// says why and so which recovery step applies.
    case accessDenied(url: URL, cause: SafariCookieStoreAccessDenial)
    /// A store exists at `url` but could not be read for another reason.
    case unreadable(url: URL)
}
