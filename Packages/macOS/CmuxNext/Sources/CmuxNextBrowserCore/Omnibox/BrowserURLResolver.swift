public import Foundation

/// Decides whether address bar text is a URL to load or a search query. The
/// rules live in Rust (cmux-url-input `TypedInput`, src/typed.rs, over
/// URLInputFFI); this type keeps the home folder and the tab's engine.
///
/// Rules, in order:
/// 1. Line breaks and tabs from a wrapped terminal paste are removed only
///    when the break comes after the URL's authority (host) has ended, so
///    `https://example.com/very/\nlong/path` loads while `example.\ncom`
///    searches.
/// 2. Explicit `http`, `https`, `file`, and `about:blank` load; with
///    `allowsChromiumSchemes` (Chromium tabs) also `chrome://` WebUI and
///    `chrome-extension://` pages and `about:` aliases of WebUI pages, in
///    Chromium's canonical form (ChromiumInternalURL: `chrome://extensions`
///    is `chrome://extensions/`); every tab also takes the `chrome://` pages
///    cmux shows itself (ChromiumPageRoute), `cmux://stashed`, the Stashed Tabs page
///    (`cmuxAppPageHosts`; the App opens it), and Mac Screen addresses
///    (`cmux://mac-screen`; an old `cmux-vnc://pair?…` pairing link, which the host refuses
///    with a word and never loads). Every other scheme (`javascript:`,
///    `data:`, `mailto:`, ...) is searched, so typed text can never run
///    script or open another app.
/// 3. `/abs/path`, `~`, and `~/path` are file URLs, spaces allowed.
/// 4. Remaining text with whitespace is a search, except an explicit
///    `http`, `https` or `file` URL whose spaces all come after its host:
///    it loads with them percent-encoded, as in Chrome.
/// 5. Scheme-less text: userinfo (`user@host`) is refused, loopback hosts
///    and non-unique hosts (private IPs, `devbox:8080`, `router/`,
///    `nas.local`) get `http`, other dotted hosts, IPv6 literals or hosts
///    with a port get `https`, and single words search.
public nonisolated struct BrowserURLResolver: Sendable {
    private let homeDirectory: URL
    public var allowsChromiumSchemes: Bool

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, allowsChromiumSchemes: Bool = false) {
        self.homeDirectory = homeDirectory
        self.allowsChromiumSchemes = allowsChromiumSchemes
    }

    /// Whether `text` holds an old Mac Screen pairing link (`cmux-vnc://pair?…`
    /// or `cmux-vnc:pair?…`, any case, anywhere in the text). The link carries a
    /// room secret, so no input surface loads, searches or sends such text to an
    /// agent: the address bar, the New Tab field and `newTab.submit` refuse it with
    /// Mac Screen's word. The New Tab page's `newTabIntent.ts` keeps the same rule;
    /// `webviews/test/fixtures/new-tab-intents.json` holds both to it.
    public static func containsPairingLink(_ text: String) -> Bool {
        URLInputFFI.containsPairingLink(text)
    }

    /// A URL to load, or nil when the text should be searched.
    public func url(for input: String) -> URL? {
        let home = homeDirectory.path(percentEncoded: false)
        return URLInputFFI.resolveTyped(input, home: home, allowsChromium: allowsChromiumSchemes)
            .flatMap { URL(string: $0) }
    }

    /// `localhost`, `*.localhost`, `127.0.0.0/8`, `::1`, and `0.0.0.0`
    /// (`host` lowercased, IPv6 brackets stripped).
    package static func isLoopback(_ host: String) -> Bool {
        URLInputFFI.isLoopbackHost(host)
    }
}
