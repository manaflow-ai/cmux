import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Local video and audio files the pane may play. The page's CSP loads media only from the pane's
/// own origin, so a checked file gets an unguessable `cmux-agent://pane/__media/<token>.<ext>` URL
/// that ``AgentPaneSchemeHandler`` serves in byte ranges. The page never names a file itself: it
/// asks `media.load` with the path from the reply, and the host checks it like a reply image.
/// Web media (an https link: a GitHub user attachment, a CI artifact) follows the reply image
/// setting and network rules; bytes that are video or audio (``sniff(_:)``) are kept as a private
/// copy in its process-owned cache and played like a file.
final class AgentPaneMediaGrants {
    static let shared = AgentPaneMediaGrants()

    /// The extensions the pane plays, with the type each is served as.
    nonisolated static let types: [String: String] = [
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime", "webm": "video/webm",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav", "flac": "audio/flac",
    ]
    /// Most files granted at once; the oldest grant goes first.
    static let maximumGrants = 256
    static let pathPrefix = "/__media/"

    private let cache: AgentPaneMediaCache

    init(cache: AgentPaneMediaCache = AgentPaneMediaCache(root: FileManager.default.temporaryDirectory.appending(path: "cmux-agent-media", directoryHint: .isDirectory))) {
        self.cache = cache
    }

    private var files: [String: URL] = [:]
    private var tokens: [URL: String] = [:]
    private var order: [String] = []
    /// The URL each web link already plays by.
    private var links: [URL: String] = [:]

    /// The URL a web link already plays by, if it was fetched.
    func fetched(_ link: URL) -> String? {
        links[link]
    }

    /// Grants the copy of web `link` at `file`.
    func grant(_ file: URL, for link: URL) -> String {
        let src = grant(file)
        links[link] = src
        return src
    }

    /// The URL the page plays `file` (canonical, already checked) by; the same file keeps its URL.
    func grant(_ file: URL) -> String {
        let name: String
        if let known = tokens[file] {
            name = known
        } else {
            name = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + "." + file.pathExtension.lowercased()
            files[name] = file
            tokens[file] = name
            order.append(name)
            if order.count > Self.maximumGrants, let oldest = order.first {
                order.removeFirst()
                if let gone = files.removeValue(forKey: oldest) {
                    tokens[gone] = nil
                    links = links.filter { !$0.value.hasSuffix("/" + oldest) }
                    // task-owner: finite eviction; the cache rejects files it does not own.
                    Task { await cache.remove(gone) }
                }
            }
        }
        return "\(AgentPaneSource.bundledScheme)://\(AgentPaneSource.bundledHost)\(Self.pathPrefix)\(name)"
    }

    /// The media type `data` really is (by its first bytes, not the link), as an extension from
    /// ``types``; nil for anything that is not video or audio.
    nonisolated static func sniff(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        func ascii(_ range: Range<Int>) -> String? {
            bytes.count >= range.upperBound ? String(bytes: bytes[range], encoding: .ascii) : nil
        }
        if ascii(4 ..< 8) == "ftyp", let brand = ascii(8 ..< 12) {
            switch brand {
            case "qt  ": return "mov"
            case "M4A ", "M4B ": return "m4a"
            default: return "mp4"
            }
        }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }
        if ascii(0 ..< 3) == "ID3" || (bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0) { return "mp3" }
        if ascii(0 ..< 4) == "RIFF", ascii(8 ..< 12) == "WAVE" { return "wav" }
        if ascii(0 ..< 4) == "fLaC" { return "flac" }
        return nil
    }

    /// Writes a private copy off the main actor, protected from other processes' orphan sweeps.
    func store(_ data: Data, ext: String) async -> URL? {
        await cache.store(data, ext: ext)
    }

    /// The origin of the agent page on the shared page host (`cmux-page://cmux.agent`), where
    /// ``AgentPageMediaResource`` serves the same grants.
    static let pageOrigin = "\(PageDescriptor.scheme)://\(PageDescriptor.agent.id)"

    /// The granted file a media URL names, on either page origin (the pane's own or the page
    /// host's), nil for any other URL.
    func file(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              Self.origins.contains("\(scheme)://\(host)"),
              url.path.hasPrefix(Self.pathPrefix) else { return nil }
        return files[String(url.path.dropFirst(Self.pathPrefix.count))]
    }

    private static let origins: Set<String> = [AgentPaneSource.bundledOrigin, pageOrigin.lowercased()]

    /// `src` (a grant, on the pane's own origin) as the page at `origin` plays it: the same token
    /// under that origin, since the page's CSP plays media only from its own (`media-src 'self'`).
    static func src(_ src: String, on origin: String) -> String {
        let own = AgentPaneSource.bundledOrigin + pathPrefix
        guard origin != AgentPaneSource.bundledOrigin, src.hasPrefix(own) else { return src }
        return origin + pathPrefix + src.dropFirst(own.count)
    }
}

extension AgentPaneModel {
    /// A video or audio file inside the roots (a video also in an attachment's read-only scope), of
    /// any size, as a URL the pane plays. Web media is refused (the pane fetches nothing itself).
    func loadReplyMedia(_ src: String) async -> [String: Any] {
        if let url = URL(string: src), let scheme = url.scheme?.lowercased(), scheme != "file" { return await loadWebMedia(url) }
        // A chat on another machine never reads this Mac's disk (cx-k21v): its agent names paths
        // there, and a path here with the same spelling is not its file.
        guard !chatIsElsewhere else { return Self.replyFailure(.pathOutsideRoots) }
        let paths = replyPaths()
        let inRoots = paths.resolve(src)
        // An attached video (a screen recording on the Desktop, outside the project) plays inline
        // from the same read-only scope its poster and Quick Look read (``AgentPaneReplyPaths/resolveVideo(_:)``).
        let attached = inRoots?.place == .root ? nil : paths.resolveVideo(src).flatMap { $0.place == .root && !$0.isFolder ? $0 : nil }
        guard let resolved = attached ?? inRoots else { return Self.replyFailure(.pathInvalid) }
        switch resolved.place {
        case .root: break
        case .denied: return Self.replyFailure(.pathDenied)
        case .outside: return Self.replyFailure(.pathOutsideRoots)
        case .missing: return Self.replyFailure(.pathInvalid)
        }
        let file = URL(fileURLWithPath: resolved.path)
        // No size cap: the scheme handler serves the player byte ranges, never the whole file.
        guard AgentPaneMediaGrants.types[file.pathExtension.lowercased()] != nil,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true
        else { return Self.replyFailure(.mediaRefused) }
        // Outside the roots the pane plays a private snapshot (a clone, free on APFS), as Quick Look
        // does, never the path: every range request reopens what it was granted, so a file rewritten
        // or a folder swapped for a link after this check never reaches the player. A reference
        // movie is refused, as Quick Look refuses it: the player would play the media it points at.
        if attached != nil {
            guard let copy = await videoSnapshot(src) else { return Self.replyFailure(.mediaRefused) }
            guard await AgentPaneVideoInfo.isSelfContained(copy), !chatIsElsewhere else {
                await AgentPaneVideoInfo.discard(copy)
                return Self.replyFailure(.mediaRefused)
            }
            return mediaReply(AgentPaneMediaGrants.shared.grant(copy))
        }
        return mediaReply(AgentPaneMediaGrants.shared.grant(file))
    }

    /// The `media.load` answer for grant `src`, on the origin this pane's page is served from.
    private func mediaReply(_ src: String) -> [String: Any] {
        AgentPaneReply.success(["src": AgentPaneMediaGrants.src(src, on: mediaOrigin)])
    }

    /// An https video or audio link, fetched under the reply image setting and network rules
    /// (after a click unless `agentPane.images.remote` is `always`); a link already fetched plays
    /// its copy again.
    private func loadWebMedia(_ url: URL) async -> [String: Any] {
        guard url.scheme?.lowercased() == "https", AgentPaneSafeFetch.isFetchable(url) else { return Self.replyFailure(.mediaRefused) }
        let grants = AgentPaneMediaGrants.shared
        let setting = replyLinks.settings().remoteImages
        if setting == .never { return Self.replyFailure(.mediaRefused) }
        if let known = grants.fetched(url) { return mediaReply(known) }
        if setting == .click, !transport.gestures.consume() { return Self.replyFailure(.gestureRequired) }
        switch await replyLinks.mediaFetcher.fetch(url) {
        case .failure(let error):
            return Self.replyFailure(error)
        case .success(let data):
            guard let ext = AgentPaneMediaGrants.sniff(data), let file = await grants.store(data, ext: ext) else {
                return Self.replyFailure(.mediaRefused)
            }
            return mediaReply(grants.grant(file, for: url))
        }
    }
}
