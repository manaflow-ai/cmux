public import Foundation

/// The page's requests for what a reply links to (decisions D4, D5, D6). Every value comes from
/// untrusted reply text, so each method has fixed param keys (any other key is refused, like
/// ``AcpmuxPaneMethods/knownParams``), length caps, and the host checks the value again before
/// any effect.
///
/// - `link.inspect {paths, urls}`: where each path is (``AgentPaneReplyPaths``) and the favicon
///   and title cmux already has for each URL (no fetch). Passive: no gesture, no effect.
/// - `link.openPath {path, line?}`: open a path chip. Spends a user gesture.
/// - `image.load {src, auto?}`: a reply image, a file inside the roots or an https URL (host
///   fetch). A web image spends a gesture unless `agentPane.images.remote` is `always` or it is
///   from a click-free site; `auto: true` (the page loading it without a click) never spends one.
/// - `media.load {src}`: a video or audio file inside the roots, as a URL the pane plays
///   (``AgentPaneMediaGrants``). Passive.
/// - `video.info {src}`: an attached video's length, size, poster and key frames
///   (``AgentPaneVideoInfo``), for a chat on this Mac. Passive.
/// - `video.probes {src}`: what follows `video.info`'s poster (its answer says `more`): the key
///   frames and the probes for the page's scene pick. Passive.
/// - `video.transcript {src}`: the speech in that video, transcribed on this Mac with timestamps
///   (``AgentPaneVideoTranscript``), for a chat on this Mac. Passive.
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
/// - `pr.inspect {url}`: what the user's GitHub CLI says about a GitHub pull request or issue a
///   reply or the pull request bars link to (its hover card). Only a plain
///   `https://github.com/<owner>/<repo>/pull/<n>` or `.../issues/<n>` is taken
///   (``githubItemURL(_:)``). Passive.
///   `cached: true` (Session Info's Changes, which asks for many links) answers from the cache
///   only and never starts a read: its links are read in batches when it registers them.
/// - `link.preview {path}`: the first lines of a text file a path chip names, for its hover card
///   (``AgentPaneReplyTextPreview``): inside the roots, or outside them only under
///   `agentPane.links.outsideRoots = open`; never a deny-listed path. A chat on another machine
///   reads nothing here and answers `{remote: true}`. Passive.
/// - `composer.copy {text, items}`: the composer's Copy or Cut of a selection with attachments
///   (``AgentPaneComposerCopyItem``): the text, then each attachment as a file, on the general
///   pasteboard (``AgentPaneImageCopies/copyComposer(text:items:in:)``). Spends a user gesture.
public nonisolated enum AgentPaneReplyRequest: Equatable, Sendable {
    case inspect(paths: [String], urls: [String])
    case openPath(String, line: Int? = nil)
    case loadImage(String, auto: Bool)
    case loadMedia(String)
    case videoInfo(String)
    /// `video.probes {src}`: what follows the poster `video.info` answered, the key frames and probes.
    case videoProbes(String)
    case videoTranscript(String)
    /// `video.frames {src, times}`: the frames at the page's picked times, in milliseconds.
    case videoFrames(String, times: [Int])
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
    case previewPath(String)
    case copyComposer(text: String, items: [AgentPaneComposerCopyItem])

    /// The methods, for ``AgentPageOps`` and ``AgentPaneRequest``.
    public static let methods: Set<String> = [
        "link.inspect", "link.openPath", "image.load", "media.load", "browser.list", "browser.openIn", "image.reveal",
        "image.openInPane", "image.copy", "image.save", "image.quickLook", "image.drag", "file.drag", "pr.inspect",
        "video.info", "video.probes", "video.transcript", "video.frames", "video.quickLook", "link.preview", "composer.copy",
    ]

    /// Each method's exact param keys (all required; `link.inspect` takes either list, and
    /// `image.load`'s `auto` may be left out).
    static let knownParams: [String: Set<String>] = [
        "link.inspect": ["paths", "urls"],
        "link.openPath": ["path", "line"],
        "image.load": ["src", "auto"],
        "media.load": ["src"],
        "video.info": ["src"],
        "video.probes": ["src"],
        "video.transcript": ["src"],
        "video.frames": ["src", "times"],
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
        "link.preview": ["path"],
        "composer.copy": ["text", "items"],
    ]

    /// Most paths or URLs in one `link.inspect`. The page gathers its chips' links across every
    /// reply on the page and asks for them in one call, so this is a bound per request.
    static let maximumInspect = 64
    /// Longest URL any method takes (the same cap as a link a browser opens from a click).
    static let maximumURL = 2048
    /// Whether the request only reads (it does not count as the page being touched).
    var isPassive: Bool {
        switch self {
        case .inspect, .listBrowsers, .loadImage, .loadMedia, .videoInfo, .videoProbes, .videoTranscript, .videoFrames, .inspectPullRequest, .previewPath: true
        case .openPath, .openIn, .revealImage, .openImageInPane, .copyImage, .saveImage, .quickLookImage, .quickLookVideo, .dragImage,
             .dragFile, .copyComposer: false
        }
    }

    /// The request for `method` and `params`, nil when they break the contract. The page's other
    /// reply requests are decoded in Rust (``AgentPaneRequestRust``); `composer.copy` builds a host
    /// type, so it stays here.
    public init?(method: String, params: [String: Any]?) {
        guard method == "composer.copy", let known = Self.knownParams[method] else { return nil }
        let params = params ?? [:]
        guard Set(params.keys).isSubset(of: known) else { return nil }
        // The text may be empty (a selection of attachments only); both keys are required.
        guard let text = params["text"] as? String, text.utf8.count <= AgentPaneComposerCopyItem.maximumText,
              !text.utf8.contains(0), let items = AgentPaneComposerCopyItem.list(params["items"]) else { return nil }
        self = .copyComposer(text: text, items: items)
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
    public static func pullRequestURL(_ text: String) -> URL? {
        // The rebuilt path is `/owner/repo/kind/n`: its kind, not a name that happens to read `pull`.
        guard let url = githubItemURL(text), url.pathComponents.dropFirst(3).first == "pull" else { return nil }
        return url
    }

    /// `text` as a GitHub pull request or issue: ``pullRequestURL(_:)``'s rule, with `issues` as
    /// well as `pull` (`https://github.com/<owner>/<repo>/issues/<n>`), rebuilt the same way. A
    /// hover card reads either (`pr.inspect`); an issue has no tab, so only a pull request keeps
    /// one.
    public static func githubItemURL(_ text: String) -> URL? {
        guard text.utf8.count <= maximumURL, let url = URL(string: text), url.scheme == "https",
              url.host(percentEncoded: false)?.lowercased() == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 4 || parts.count == 5, parts[2] == "pull" || parts[2] == "issues", !parts[0].allSatisfy({ $0 == "." }),
              !parts[1].allSatisfy({ $0 == "." }) else { return nil }
        func only(_ part: String, _ allowed: (Unicode.Scalar) -> Bool, max: Int) -> Bool {
            !part.isEmpty && part.unicodeScalars.count <= max && part.unicodeScalars.allSatisfy(allowed)
        }
        let name: (Unicode.Scalar) -> Bool = { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)) }
        let digit: (Unicode.Scalar) -> Bool = { ("0"..."9").contains($0) }
        guard only(parts[0], name, max: 100), only(parts[1], name, max: 100), !parts[0].hasPrefix("-"), !parts[1].hasPrefix("-"),
              only(parts[3], digit, max: 10), !parts[3].hasPrefix("0") else { return nil }
        if parts.count == 5, parts[2] != "pull" || !only(parts[4], { ("a"..."z").contains($0) }, max: 20) { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])/\(parts[2])/\(parts[3])")
    }
}
