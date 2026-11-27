public import Foundation

/// A typed Chromium internal page (`chrome://`, `chrome-extension://`, or an
/// `about:` alias of a `chrome://` page) in Chromium's canonical form, so
/// every spelling of one page is one URL:
///
/// - `chrome` and `chrome-extension` are standard schemes: scheme and host
///   are lowercased, the slashes after the colon are optional, and an empty
///   path becomes `/` (`chrome://extensions?id=x` is
///   `chrome://extensions/?id=x`), as GURL canonicalizes them.
/// - `about:<page>` is `chrome://<page>`, as `url_formatter::FixupURL` maps
///   it; `about:blank` and `about:srcdoc` are not aliases.
/// - Userinfo, a port, or a host with other characters than letters, digits,
///   `-`, `_` and `.` is not an internal page (nil).
public nonisolated struct ChromiumInternalURL: Sendable, Equatable {
    public let url: URL

    /// Schemes whose pages only a Chromium tab shows.
    package static let chromiumSchemes: Set<String> = ["chrome", "chrome-extension"]

    /// Typed text that names a Chromium internal page, in canonical form;
    /// nil for anything else (`about:blank` included: every engine has it).
    /// The rule is Rust's (cmux-url-input src/chromium.rs, over URLInputFFI).
    public init?(typed text: String) {
        guard let page = URLInputFFI.chromiumInternalURL(text), let url = URL(string: page) else { return nil }
        self.url = url
    }

    /// Whether `url` is a page only a Chromium tab can show.
    public static func needsChromium(_ url: URL) -> Bool {
        url.scheme.map { chromiumSchemes.contains($0.lowercased()) } ?? false
    }
}
