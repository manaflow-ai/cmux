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
public nonisolated enum AgentPaneReplyRequest: Equatable, Sendable {
    case inspect(paths: [String], urls: [String])
    case openPath(String)
    case loadImage(String)
    case loadMedia(String)
    case listBrowsers
    case openIn(url: URL, browserId: String)

    /// The methods, for ``AgentPageOps`` and ``AgentPaneRequest``.
    public static let methods: Set<String> = ["link.inspect", "link.openPath", "image.load", "media.load", "browser.list", "browser.openIn"]

    /// Each method's exact param keys (all required; `link.inspect` takes either list).
    static let knownParams: [String: Set<String>] = [
        "link.inspect": ["paths", "urls"],
        "link.openPath": ["path"],
        "image.load": ["src"],
        "media.load": ["src"],
        "browser.list": [],
        "browser.openIn": ["url", "browserId"],
    ]

    /// Most paths or URLs in one `link.inspect` (one reply's chips).
    static let maximumInspect = 64
    /// Longest URL any method takes (the same cap as a link a browser opens from a click).
    static let maximumURL = 2048

    /// Whether the request only reads (it does not count as the page being touched).
    var isPassive: Bool {
        switch self {
        case .inspect, .listBrowsers, .loadImage, .loadMedia: true
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
}
