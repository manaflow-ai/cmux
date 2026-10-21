public import Foundation

/// The page's requests for what a reply links to (decisions D4, D5, D6). Every value comes from
/// untrusted reply text, so each method has fixed param keys (any other key is refused, like
/// ``AcpmuxPaneMethods/knownParams``), length caps, and the host checks the value again before
/// any effect.
///
/// - `link.inspect {paths, urls}`: where each path is (``AgentPaneReplyPaths``) and the favicon
///   and title cmux already has for each URL (no fetch). Passive: no gesture, no effect.
/// - `link.openPath {path}`: open a path chip. Spends a user gesture.
/// - `image.load {src}`: a reply image, a file inside the roots or an https URL (host fetch).
///   A web image spends a gesture unless `agentPane.images.remote` is `always`.
/// - `media.load {src}`: a video or audio file inside the roots, as a URL the pane plays
///   (``AgentPaneMediaGrants``). Passive.
/// - `browser.list {}`: the installed browsers, by opaque id. Passive.
/// - `browser.openIn {url, browserId}`: open a validated http(s) URL in one of them. Spends a
///   user gesture.
/// - `pr.inspect {url}`: what the user's GitHub CLI says about a GitHub pull request a reply or
///   the pull request bars link to (its hover card). Only a plain
///   `https://github.com/<owner>/<repo>/pull/<n>` is taken (``pullRequestURL(_:)``). Passive.
public nonisolated enum AgentPaneReplyRequest: Equatable, Sendable {
    case inspect(paths: [String], urls: [String])
    case openPath(String)
    case loadImage(String)
    case loadMedia(String)
    case listBrowsers
    case openIn(url: URL, browserId: String)
    case inspectPullRequest(URL)

    /// The methods, for ``AgentPageOps`` and ``AgentPaneRequest``.
    public static let methods: Set<String> = ["link.inspect", "link.openPath", "image.load", "media.load", "browser.list", "browser.openIn", "pr.inspect"]

    /// Each method's exact param keys (all required; `link.inspect` takes either list).
    static let knownParams: [String: Set<String>] = [
        "link.inspect": ["paths", "urls"],
        "link.openPath": ["path"],
        "image.load": ["src"],
        "media.load": ["src"],
        "browser.list": [],
        "browser.openIn": ["url", "browserId"],
        "pr.inspect": ["url"],
    ]

    /// Most paths or URLs in one `link.inspect` (one reply's chips).
    static let maximumInspect = 64
    /// Longest URL any method takes (the same cap as a link a browser opens from a click).
    static let maximumURL = 2048

    /// Whether the request only reads (it does not count as the page being touched).
    var isPassive: Bool {
        switch self {
        case .inspect, .listBrowsers, .loadImage, .loadMedia, .inspectPullRequest: true
        case .openPath, .openIn: false
        }
    }

    /// The request for `method` and `params`, nil when they break the contract.
    init?(method: String, params: [String: Any]?) {
        guard let known = Self.knownParams[method] else { return nil }
        let params = params ?? [:]
        guard Set(params.keys).isSubset(of: known) else { return nil }
        func text(_ key: String, _ limit: Int) -> String? {
            guard let value = params[key] as? String, !value.isEmpty, value.utf8.count <= limit, !value.utf8.contains(0) else { return nil }
            return value
        }
        func list(_ key: String, _ limit: Int) -> [String]? {
            guard let raw = params[key] else { return [] }
            guard let values = raw as? [Any], values.count <= Self.maximumInspect else { return nil }
            var out: [String] = []
            for value in values {
                guard let value = value as? String, !value.isEmpty, value.utf8.count <= limit, !value.utf8.contains(0) else { return nil }
                if !out.contains(value) { out.append(value) }
            }
            return out
        }
        switch method {
        case "link.inspect":
            guard let paths = list("paths", AgentPaneReplyPaths.maximumLength), let urls = list("urls", Self.maximumURL) else { return nil }
            self = .inspect(paths: paths, urls: urls)
        case "link.openPath":
            guard let path = text("path", AgentPaneReplyPaths.maximumLength) else { return nil }
            self = .openPath(path)
        case "image.load":
            guard let src = text("src", Self.maximumURL) else { return nil }
            self = .loadImage(src)
        case "media.load":
            guard let src = text("src", Self.maximumURL) else { return nil }
            self = .loadMedia(src)
        case "browser.list":
            self = .listBrowsers
        case "browser.openIn":
            guard let raw = text("url", Self.maximumURL), let url = Self.webURL(raw),
                  let id = text("browserId", 64) else { return nil }
            self = .openIn(url: url, browserId: id)
        case "pr.inspect":
            guard let raw = text("url", Self.maximumURL), let url = Self.pullRequestURL(raw) else { return nil }
            self = .inspectPullRequest(url)
        default:
            return nil
        }
    }

    /// `text` as a URL a browser may open: http or https, a host, no user info, at most
    /// ``maximumURL`` characters. Nil for anything else (`javascript:`, `file:`, `cmux:`).
    static func webURL(_ text: String) -> URL? {
        guard text.utf8.count <= maximumURL, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return url
    }

    /// `text` as a GitHub pull request, `https://github.com/<owner>/<repo>/pull/<n>` (a trailing
    /// slash or one of its tabs, as `/files`, names the same one), rebuilt from its parts. Nil for
    /// anything else, so nothing but that URL ever reaches `gh`: no other host, no user info, no
    /// query or fragment, and no part that starts with `-`.
    static func pullRequestURL(_ text: String) -> URL? {
        guard text.utf8.count <= maximumURL, let url = URL(string: text), url.scheme == "https",
              url.host(percentEncoded: false)?.lowercased() == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 4 || parts.count == 5, parts[2] == "pull", !parts[0].allSatisfy({ $0 == "." }),
              !parts[1].allSatisfy({ $0 == "." }) else { return nil }
        func only(_ part: String, _ allowed: (Unicode.Scalar) -> Bool, max: Int) -> Bool {
            !part.isEmpty && part.unicodeScalars.count <= max && part.unicodeScalars.allSatisfy(allowed)
        }
        let name: (Unicode.Scalar) -> Bool = { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)) }
        let digit: (Unicode.Scalar) -> Bool = { ("0"..."9").contains($0) }
        guard only(parts[0], name, max: 100), only(parts[1], name, max: 100), !parts[0].hasPrefix("-"), !parts[1].hasPrefix("-"),
              only(parts[3], digit, max: 10), !parts[3].hasPrefix("0") else { return nil }
        if parts.count == 5, !only(parts[4], { ("a"..."z").contains($0) }, max: 20) { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])/pull/\(parts[3])")
    }
}
