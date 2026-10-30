public import Foundation
import CryptoKit

/// Release media the changelog page can show (cx-urd.61.1). The page's CSP admits only `data:`
/// and same-origin media, so the owner side inlines each checked picture or short video as a `data:` URL after checking
/// it. Sources, most trusted first:
/// - a highlight's media in the signed notes (`url` + `sha256`): fetched over https, kept only
///   when its SHA-256 matches the signed hash;
/// - a What's New entry's `media/<version>/<file>` path: the copy bundled with the app (the
///   newest versions; signed with the app), a DEV build's `CMUX_NEXT_WHATS_NEW_DIR`, else the
///   first-party site (`https://cmux.com/whats-new/`, https only, no other host).
/// Every file must sniff as PNG, JPEG, GIF, WebP or an ISO-BMFF video and fit the size cap. Fetched files are
/// cached (highlights by hash, documents by path), so the page shows them offline.
/// The build's nightly reel is a video the page links, never inlines (``reel(build:)``): its URL
/// only when the build's `reel.json` (scripts/cmux-next/media/reel.py) says `reel.mp4` was built.
nonisolated public struct ReleaseMediaStore: Sendable {
    public let cache: URL
    public let bundledDirectories: [URL]
    /// The first-party site's What's New folder; nil turns the site source off.
    public let siteBase: URL?
    /// Where the nightly publishes each build's reel (`<build>/reel.json`); nil turns reels off.
    public let reelBase: URL?
    private let fetcher: any AppcastFetching
    /// Results of this store's earlier calls (a failure too), so a page asks the network once.
    private let memo = Memo()

    /// The largest media file the page inlines (bytes).
    static let maxMediaBytes = 4 << 20
    /// Kept for callers that named the old picture-only limit.
    static let maxImageBytes = maxMediaBytes

    public init(cache: URL, bundledDirectories: [URL], fetcher: any AppcastFetching = URLSessionAppcastFetcher(deadline: 5, followsRedirects: false),
                siteBase: URL? = URL(string: "https://cmux.com/whats-new/"),
                reelBase: URL? = URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/nightly-next/")) {
        self.cache = cache
        self.reelBase = reelBase
        self.bundledDirectories = bundledDirectories
        self.fetcher = fetcher
        self.siteBase = siteBase
    }

    /// `notes` with every media reference replaced by a checked `data:` URL; media that fails a
    /// check is dropped, never passed through as a remote URL. Every file loads at once (one
    /// fetch deadline in total, not one per file), and the page's own memo answers repeat calls.
    @concurrent
    public func inlined(_ notes: ReleaseNotes) async -> ReleaseNotes {
        enum Source: Hashable, Sendable { case highlight(sha256: String, url: URL), document(String) }
        var sources = Set<Source>()
        for highlight in notes.highlights { highlight.media.forEach { sources.insert(.highlight(sha256: $0.sha256.lowercased(), url: $0.url)) } }
        for entry in notes.whatsNew?.entries ?? [] {
            if let media = entry.media { sources.formUnion([.document(media.light), .document(media.dark)]) }
        }
        var resolved: [Source: URL] = [:]
        await withTaskGroup(of: (Source, URL?).self) { group in
            for source in sources {
                group.addTask {
                    let key: String
                    switch source {
                    case .highlight(let hash, _): key = "h:" + hash
                    case .document(let path): key = "d:" + path
                    }
                    if let known = await memo.value(key) { return (source, known) }
                    let data: Data?
                    switch source {
                    case .highlight(let hash, let url): data = await highlightData(sha256: hash, url: url)
                    case .document(let path): data = await documentData(path)
                    }
                    let url = data.flatMap(Self.dataURL)
                    await memo.set(key, url)
                    return (source, url)
                }
            }
            for await (source, url) in group { resolved[source] = url }
        }
        var notes = notes
        for index in notes.highlights.indices {
            notes.highlights[index].media = notes.highlights[index].media.compactMap { media in
                resolved[.highlight(sha256: media.sha256.lowercased(), url: media.url)].map {
                    ReleaseNotes.Media(url: $0, sha256: media.sha256, kind: Self.kindName(for: $0), alt: media.alt)
                }
            }
        }
        if var document = notes.whatsNew {
            for index in document.entries.indices {
                guard let media = document.entries[index].media else { continue }
                let light = resolved[.document(media.light)], dark = resolved[.document(media.dark)]
                if let first = light ?? dark {
                    document.entries[index].media = WhatsNewDocument.Media(
                        kind: Self.kindName(for: first), light: first.absoluteString, dark: (dark ?? first).absoluteString, alt: media.alt)
                } else {
                    document.entries[index].media = nil
                }
            }
            notes.whatsNew = document
        }
        return notes
    }

    // MARK: Sources

    /// A highlight's file: cached by its signed hash, else fetched (https) and checked.
    @concurrent
    private func highlightData(sha256 hash: String, url: URL) async -> Data? {
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit), Self.isPublicHighlightURL(url) else { return nil }
        let cached = cache.appending(path: "sha256-\(hash)")
        // concurrency-allow: @concurrent, never on the main thread; one cached file.
        if let data = try? Data(contentsOf: cached), Self.sha256(data) == hash, Self.admits(data) { return data }
        guard let data = try? await fetcher.fetch(url), Self.sha256(data) == hash, Self.admits(data) else { return nil }
        store(data, at: cached)
        return data
    }

    /// A What's New document's `media/<version>/<file>`: bundled, then cached, then the site.
    @concurrent
    private func documentData(_ path: String) async -> Data? {
        guard WhatsNewDocument.Media.isSafe(path) else { return nil }
        for directory in bundledDirectories {
            // concurrency-allow: @concurrent, never on the main thread; one bundled file.
            if let data = try? Data(contentsOf: directory.appending(path: path)), Self.admits(data) { return data }
        }
        let cached = cache.appending(path: "site").appending(path: path)
        // concurrency-allow: @concurrent, never on the main thread; one cached file.
        if let data = try? Data(contentsOf: cached), Self.admits(data) { return data }
        guard let siteBase, siteBase.scheme == "https", let url = URL(string: path, relativeTo: siteBase)?.absoluteURL,
              url.host == siteBase.host, url.path.hasPrefix(siteBase.path),
              let data = try? await fetcher.fetch(url), Self.admits(data) else { return nil }
        store(data, at: cached)
        return data
    }

    /// The build's `reel.mp4` when its `reel.json` names it (`"reel": null` when no pull request
    /// had a clip). Build ids are digits only, so the URL stays in the reel folder. Its own call:
    /// the notes never wait on the network for it.
    @concurrent
    public func reel(build: String) async -> URL? {
        guard let reelBase, reelBase.scheme == "https", !build.isEmpty, build.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let key = "r:" + build
        if let known = await memo.value(key) { return known }
        struct Report: Decodable { let reel: String? }
        let folder = reelBase.appending(path: build, directoryHint: .isDirectory)
        var url: URL?
        if let data = try? await fetcher.fetch(folder.appending(path: "reel.json")), data.count <= 1 << 20,
           (try? JSONDecoder().decode(Report.self, from: data))?.reel == "reel.mp4" {
            url = folder.appending(path: "reel.mp4")
        }
        await memo.set(key, url)
        return url
    }

    private func store(_ data: Data, at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Checks

    /// Media kinds the page can safely inline after sniffing bytes. The WebView receives a data URL,
    /// so a signed notes URL never becomes a live remote resource in the page.
    enum Kind: String {
        case png = "image/png", jpeg = "image/jpeg", gif = "image/gif", webp = "image/webp", video = "video/mp4"
    }

    /// The file type from its first bytes (never from a name or a server header).
    static func kind(of data: Data) -> Kind? {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 12 else { return nil }
        if b[0...7] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if b[0...2] == [0xFF, 0xD8, 0xFF] { return .jpeg }
        if b[0...3] == [0x47, 0x49, 0x46, 0x38] { return .gif }
        if b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return .webp }
        if b[4...7] == [0x66, 0x74, 0x79, 0x70] { return .video }
        return nil
    }

    static func admits(_ data: Data) -> Bool {
        kind(of: data) != nil && data.count <= maxMediaBytes
    }

    static func dataURL(_ data: Data) -> URL? {
        guard admits(data), let kind = kind(of: data) else { return nil }
        return URL(string: "data:\(kind.rawValue);base64,\(data.base64EncodedString())")
    }

    static func kindName(for dataURL: URL) -> String {
        dataURL.absoluteString.hasPrefix("data:video/") ? "video" : "image"
    }

    /// Signed release notes may point only at this repository's public media branch.
    static func isPublicHighlightURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "raw.githubusercontent.com",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let decodedPath = components.percentEncodedPath.removingPercentEncoding,
              decodedPath.hasPrefix("/manaflow-ai/cmux/pr-media/"),
              !decodedPath.contains("%"), !decodedPath.contains("\\") else { return false }
        return !decodedPath.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == "." || $0 == ".." }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Inlined media by source key; a nil value is a failure remembered for this store's life.
    actor Memo {
        private var values: [String: URL?] = [:]
        func value(_ key: String) -> URL?? { values[key] }
        func set(_ key: String, _ url: URL?) { values[key] = .some(url) }
    }
}
