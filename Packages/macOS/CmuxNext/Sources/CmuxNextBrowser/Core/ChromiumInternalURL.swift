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
    static let chromiumSchemes: Set<String> = ["chrome", "chrome-extension"]

    /// Typed text that names a Chromium internal page, in canonical form;
    /// nil for anything else (`about:blank` included: every engine has it).
    public init?(typed text: String) {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon].lowercased()
        guard Self.chromiumSchemes.contains(scheme) || scheme == "about" else { return nil }
        self.init(text, scheme: scheme)
    }

    /// Whether `url` is a page only a Chromium tab can show.
    public static func needsChromium(_ url: URL) -> Bool {
        url.scheme.map { chromiumSchemes.contains($0.lowercased()) } ?? false
    }

    /// `scheme` is the lowercased scheme of `text`.
    init?(_ text: String, scheme: String) {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        var rest = Substring(text[text.index(after: colon)...])
        let canonicalScheme: String
        switch scheme {
        case "chrome", "chrome-extension":
            canonicalScheme = scheme
        case "about":
            let page = rest.prefix { !"?#".contains($0) }.lowercased()
            guard page != "blank", page != "srcdoc" else { return nil }
            canonicalScheme = "chrome"
        default:
            return nil
        }
        rest = rest.drop { $0 == "/" }
        let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let host = rest[..<authorityEnd].lowercased()
        guard !host.isEmpty, host.allSatisfy(Self.isHostCharacter) else { return nil }
        var tail = String(rest[authorityEnd...])
        if !tail.hasPrefix("/") { tail = "/" + tail }
        guard let components = URLComponents(string: "\(canonicalScheme)://\(host)\(tail)"),
              components.host == host, let url = components.url else {
            return nil
        }
        self.url = url
    }

    private static func isHostCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "-_.".contains(character))
    }
}
