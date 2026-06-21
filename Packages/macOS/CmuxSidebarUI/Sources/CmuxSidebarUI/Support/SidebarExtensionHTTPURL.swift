public import Foundation

extension URL {
    /// Returns the URL only when `urlString` is a valid absolute `http` or
    /// `https` URL with a non-empty host, otherwise `nil`. Drained
    /// byte-identically from `VerticalTabsSidebar`'s
    /// `cmuxSidebarExtensionRequiredHTTPURL` so the extension-sidebar action
    /// handler rejects non-`http`/`https`, schemeless, or hostless URLs without
    /// an app-target helper.
    public static func sidebarExtensionHTTPURL(from urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }
}

/// The outcome of validating an optional sidebar-extension URL string.
///
/// Mirrors the app target's `cmuxSidebarExtensionOptionalHTTPURL` tuple
/// semantics: an empty or `nil` string is accepted with no URL (the action
/// proceeds without one), a valid `http`/`https` URL is accepted with that URL,
/// and anything else is rejected.
public struct SidebarExtensionOptionalHTTPURL: Sendable, Equatable {
    /// The validated URL, or `nil` when the input was empty or rejected.
    public let url: URL?
    /// `true` when the input was empty or a valid `http`/`https` URL.
    public let accepted: Bool

    /// Validates an optional URL string. An empty or `nil` string yields
    /// `accepted == true` with `url == nil`; a valid `http`/`https` URL yields
    /// `accepted == true` with the URL; any other string yields
    /// `accepted == false` with `url == nil`.
    public init(validating urlString: String?) {
        guard let urlString, !urlString.isEmpty else {
            self.url = nil
            self.accepted = true
            return
        }
        guard let url = URL.sidebarExtensionHTTPURL(from: urlString) else {
            self.url = nil
            self.accepted = false
            return
        }
        self.url = url
        self.accepted = true
    }
}
