public import Foundation

/// The page's requests for what a reply links to (decisions D4, D5, D6). Every value comes from
/// untrusted reply text, so each method has fixed param keys (any other key is refused, like
/// ``AcpmuxPaneMethods/knownParams``), length caps, and the host checks the value again before
/// any effect.
///
/// - `link.inspect {paths, urls}`: where each path is (``AgentPaneReplyPaths``) and the favicon
///   and title cmux already has for each URL (no fetch). Passive: no gesture, no effect.
/// - `link.openPath {path}`: open a path chip. Spends a user gesture.
/// - `image.load {src, auto?}`: a reply image, a file inside the roots or an https URL (host
///   fetch). A web image spends a gesture unless `agentPane.images.remote` is `always` or it is
///   from a click-free site; `auto: true` (the page loading it without a click) never spends one.
/// - `media.load {src}`: a video or audio file inside the roots, as a URL the pane plays
///   (``AgentPaneMediaGrants``). Passive.
/// - `video.info {src}`: an attached video's length, size, poster and key frames
///   (``AgentPaneVideoInfo``), for a chat on this Mac. Passive.
/// - `video.quickLook {src}`: plays that video in Quick Look. Spends a user gesture.
/// - `browser.list {}`: the installed browsers, by opaque id. Passive.
/// - `browser.openIn {url, browserId}`: open a validated http(s) URL in one of them. Spends a
///   user gesture.
/// - `image.reveal {src, name, path?}`: show an image the viewer holds in Finder: the file `path`
///   names when it is one inside the roots of a local chat, else a copy of the `data:` image `src`
///   (``AgentPaneImageCopies``). Spends one user gesture.
/// - `image.openInPane {src, name}`: open a copy of a `data:` image in a cmux browser pane. Spends
///   a user gesture.
/// - `image.copy {src, name}`, `image.save {src, name}`, `image.quickLook {src, name}`: the context
///   menu's Copy Image (the copy and its bytes on the pasteboard), Save Image As… (the save panel,
///   named for the image) and Quick Look, each on a copy of a `data:` image. Spend a user gesture.
/// - `image.drag {src, name}`, `file.drag {path}`: a drag the person started on an image or a file
///   chip, as the host's own drag of a real file (the image's named copy; the file only inside the
///   roots of a local chat). Need the press still held (``AgentPaneReplyLinks/mouseHeld``).
/// - `pr.inspect {url}`: what the user's GitHub CLI says about a GitHub pull request a reply or
///   the pull request bars link to (its hover card). Only a plain
///   `https://github.com/<owner>/<repo>/pull/<n>` is taken (``pullRequestURL(_:)``). Passive.
///   `cached: true` (the Inspector's Changes, which asks for many links) answers from the cache
///   only and never starts a read: its links are read in batches when it registers them.
public nonisolated enum AgentPaneReplyRequest: Equatable, Sendable {
    case inspect(paths: [String], urls: [String])
    case openPath(String)
    case loadImage(String, auto: Bool)
    case loadMedia(String)
    case videoInfo(String)
    case quickLookVideo(String)
    case listBrowsers
    case openIn(url: URL, browserId: String)
    case revealImage(src: String, name: String, path: String?)
    case openImageInPane(src: String, name: String)
    case copyImage(src: String, name: String)
    case saveImage(src: String, name: String)
    case quickLookImage(src: String, name: String)
    case dragImage(src: String, name: String)
    case dragFile(String)
    case inspectPullRequest(URL, cached: Bool = false)

    /// The methods, for ``AgentPageOps`` and ``AgentPaneRequest``.
    public static let methods: Set<String> = [
        "link.inspect", "link.openPath", "image.load", "media.load", "browser.list", "browser.openIn", "image.reveal",
        "image.openInPane", "image.copy", "image.save", "image.quickLook", "image.drag", "file.drag", "pr.inspect",
        "video.info", "video.quickLook",
    ]

    /// Each method's exact param keys (all required; `link.inspect` takes either list, and
    /// `image.load`'s `auto` may be left out).
    static let knownParams: [String: Set<String>] = [
        "link.inspect": ["paths", "urls"],
        "link.openPath": ["path"],
        "image.load": ["src", "auto"],
        "media.load": ["src"],
        "video.info": ["src"],
        "video.quickLook": ["src"],
        "browser.list": [],
        "browser.openIn": ["url", "browserId"],
        "image.reveal": ["src", "name", "path"],
        "image.openInPane": ["src", "name"],
        "image.copy": ["src", "name"],
        "image.save": ["src", "name"],
        "image.quickLook": ["src", "name"],
        "image.drag": ["src", "name"],
        "file.drag": ["path"],
        "pr.inspect": ["url", "cached"],
    ]

    /// Most paths or URLs in one `link.inspect`. The page gathers its chips' links across every
    /// reply on the page and asks for them in one call, so this is a bound per request.
    static let maximumInspect = 64
    /// Longest URL any method takes (the same cap as a link a browser opens from a click).
    static let maximumURL = 2048
    /// Longest `data:` image the viewer actions take (base64 of ``AgentPaneImageCopies/maximumBytes``).
    static let maximumImageSource = AgentPaneImageCopies.maximumBytes / 3 * 4 + 64
    /// Longest image name (its alt text) the viewer actions keep: a longer one is cut to it, not
    /// refused, since alt text has no length limit (``AgentPaneImageCopies/fileName(_:data:type:)``
    /// cuts it again to fit a file name).
    static let maximumImageName = 512

    /// `name` cut to at most ``maximumImageName`` UTF-8 bytes, on a character boundary.
    static func imageName(_ name: String) -> String {
        guard name.utf8.count > maximumImageName else { return name }
        var bytes = 0
        var end = name.startIndex
        for index in name.indices {
            let next = name.index(after: index)
            bytes += name[index..<next].utf8.count
            guard bytes <= maximumImageName else { break }
            end = next
        }
        return String(name[..<end])
    }

    /// Whether the request only reads (it does not count as the page being touched).
    var isPassive: Bool {
        switch self {
        case .inspect, .listBrowsers, .loadImage, .loadMedia, .videoInfo, .inspectPullRequest: true
        case .openPath, .openIn, .revealImage, .openImageInPane, .copyImage, .saveImage, .quickLookImage, .quickLookVideo, .dragImage,
             .dragFile: false
        }
    }

    /// The request for `method` and `params`, nil when they break the contract.
    public init?(method: String, params: [String: Any]?) {
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
            let auto = params["auto"]
            guard auto == nil || auto is Bool else { return nil }
            self = .loadImage(src, auto: auto as? Bool ?? false)
        case "media.load":
            guard let src = text("src", Self.maximumURL) else { return nil }
            self = .loadMedia(src)
        case "video.info", "video.quickLook":
            guard let src = text("src", AgentPaneReplyPaths.maximumLength) else { return nil }
            self = method == "video.info" ? .videoInfo(src) : .quickLookVideo(src)
        case "browser.list":
            self = .listBrowsers
        case "browser.openIn":
            guard let raw = text("url", Self.maximumURL), let url = Self.webURL(raw),
                  let id = text("browserId", 64) else { return nil }
            self = .openIn(url: url, browserId: id)
        case "file.drag":
            guard let path = text("path", AgentPaneReplyPaths.maximumLength) else { return nil }
            self = .dragFile(path)
        case "image.reveal", "image.openInPane", "image.copy", "image.save", "image.quickLook", "image.drag":
            // `src` is the image itself; the name may be empty (an image without alt text).
            guard let src = text("src", Self.maximumImageSource), src.hasPrefix("data:"),
                  let raw = params["name"] as? String, !raw.utf8.contains(0) else { return nil }
            let name = Self.imageName(raw)
            switch method {
            case "image.openInPane": self = .openImageInPane(src: src, name: name); return
            case "image.copy": self = .copyImage(src: src, name: name); return
            case "image.save": self = .saveImage(src: src, name: name); return
            case "image.quickLook": self = .quickLookImage(src: src, name: name); return
            case "image.drag": self = .dragImage(src: src, name: name); return
            default: break
            }
            if params["path"] != nil {
                guard let path = text("path", AgentPaneReplyPaths.maximumLength) else { return nil }
                self = .revealImage(src: src, name: name, path: path)
            } else {
                self = .revealImage(src: src, name: name, path: nil)
            }
        case "pr.inspect":
            guard let raw = text("url", Self.maximumURL), let url = Self.pullRequestURL(raw) else { return nil }
            let cached = params["cached"].map { $0 as? Bool } ?? false
            guard let cached else { return nil }
            self = .inspectPullRequest(url, cached: cached)
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
