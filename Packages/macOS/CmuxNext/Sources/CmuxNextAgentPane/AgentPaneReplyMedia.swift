import CmuxNextSettings
import Foundation

/// Local video and audio files the pane may play. The page's CSP loads media only from the pane's
/// own origin, so a checked file gets an unguessable `cmux-agent://pane/__media/<token>.<ext>` URL
/// that ``AgentPaneSchemeHandler`` serves in byte ranges. The page never names a file itself: it
/// asks `media.load` with the path from the reply, and the host checks it like a reply image.
/// Web media (an https link: a GitHub user attachment, a CI artifact) follows the reply image
/// setting and network rules; bytes that are video or audio (``sniff(_:)``) are kept as a private
/// copy in ``cacheFolder`` and played like a file.
final class AgentPaneMediaGrants {
    static let shared = AgentPaneMediaGrants()

    /// The extensions the pane plays, with the type each is served as.
    nonisolated static let types: [String: String] = [
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime", "webm": "video/webm",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav", "flac": "audio/flac",
    ]
    /// Largest file the pane plays (it reads only the ranges the player asks for).
    nonisolated static let maximumBytes = 4 << 30
    /// Most files granted at once; the oldest grant goes first.
    static let maximumGrants = 256
    static let pathPrefix = "/__media/"

    /// Where web media copies live; one is removed when its grant goes.
    nonisolated static let cacheFolder = FileManager.default.temporaryDirectory.appending(path: "cmux-agent-media", directoryHint: .isDirectory)

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
                    if gone.deletingLastPathComponent().standardizedFileURL == Self.cacheFolder.standardizedFileURL {
                        try? FileManager.default.removeItem(at: gone)
                    }
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

    /// Writes a web media copy (readable by this user only) and returns its file.
    @concurrent nonisolated static func store(_ data: Data, ext: String) async -> URL? {
        let fm = FileManager.default
        // concurrency-allow: @concurrent, so this write never runs on the main actor
        guard (try? fm.createDirectory(at: cacheFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
        else { return nil }
        let file = cacheFolder.appending(path: UUID().uuidString.lowercased() + "." + ext)
        guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        return file.resolvingSymlinksInPath()
    }

    /// The granted file a media URL names, nil for any other URL.
    func file(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == AgentPaneSource.bundledScheme,
              url.host?.lowercased() == AgentPaneSource.bundledHost,
              url.path.hasPrefix(Self.pathPrefix) else { return nil }
        return files[String(url.path.dropFirst(Self.pathPrefix.count))]
    }
}

extension AgentPaneModel {
    /// A video or audio file inside the roots, as a URL the pane plays. Web media is refused
    /// (the pane fetches nothing itself).
    func loadReplyMedia(_ src: String) async -> [String: Any] {
        if let url = URL(string: src), let scheme = url.scheme?.lowercased(), scheme != "file" { return await loadWebMedia(url) }
        guard let resolved = replyPaths().resolve(src) else { return Self.replyFailure(.pathInvalid) }
        switch resolved.place {
        case .root: break
        case .denied: return Self.replyFailure(.pathDenied)
        case .outside: return Self.replyFailure(.pathOutsideRoots)
        case .missing: return Self.replyFailure(.pathInvalid)
        }
        let file = URL(fileURLWithPath: resolved.path)
        guard AgentPaneMediaGrants.types[file.pathExtension.lowercased()] != nil,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= AgentPaneMediaGrants.maximumBytes
        else { return Self.replyFailure(.mediaRefused) }
        return AgentPaneReply.success(["src": AgentPaneMediaGrants.shared.grant(file)])
    }

    /// An https video or audio link, fetched under the reply image setting and network rules
    /// (after a click unless `agentPane.images.remote` is `always`); a link already fetched plays
    /// its copy again.
    private func loadWebMedia(_ url: URL) async -> [String: Any] {
        guard url.scheme?.lowercased() == "https", AgentPaneSafeFetch.isFetchable(url) else { return Self.replyFailure(.mediaRefused) }
        let grants = AgentPaneMediaGrants.shared
        let setting = replyLinks.settings().remoteImages
        if setting == .never { return Self.replyFailure(.mediaRefused) }
        if let known = grants.fetched(url) { return AgentPaneReply.success(["src": known]) }
        if setting == .click, !transport.gestures.consume() { return Self.replyFailure(.gestureRequired) }
        switch await replyLinks.mediaFetcher.fetch(url) {
        case .failure(let error):
            return Self.replyFailure(error)
        case .success(let data):
            guard let ext = AgentPaneMediaGrants.sniff(data), let file = await AgentPaneMediaGrants.store(data, ext: ext) else {
                return Self.replyFailure(.mediaRefused)
            }
            return AgentPaneReply.success(["src": grants.grant(file, for: url)])
        }
    }
}
