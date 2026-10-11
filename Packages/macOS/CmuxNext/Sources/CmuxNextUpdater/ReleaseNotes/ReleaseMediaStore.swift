public import Foundation
import CryptoKit

/// Release media the changelog page can show (cx-urd.61.1). The page's CSP admits only `data:`
/// and same-origin images, so the owner side inlines each picture as a `data:` URL after checking
/// it. Sources, most trusted first:
/// - a highlight's media in the signed notes (`url` + `sha256`): fetched over https, kept only
///   when its SHA-256 matches the signed hash;
/// - a What's New entry's `media/<version>/<file>` path: the copy bundled with the app (the
///   newest versions; signed with the app), a DEV build's `CMUX_NEXT_WHATS_NEW_DIR`, else the
///   first-party site (`https://cmux.com/whats-new/`, https only, no other host).
/// Every file must sniff as PNG, JPEG, GIF, WebP or MP4 and fit the size cap. Fetched files are
/// cached (highlights by hash, documents by path), so the page shows them offline.
nonisolated public struct ReleaseMediaStore: Sendable {
    public let cache: URL
    public let bundledDirectories: [URL]
    /// The first-party site's What's New folder; nil turns the site source off.
    public let siteBase: URL?
    private let fetcher: any AppcastFetching

    /// The largest picture or clip the page inlines (bytes).
    static let maxImageBytes = 4 << 20
    static let maxVideoBytes = 8 << 20

    public init(cache: URL, bundledDirectories: [URL], fetcher: any AppcastFetching = URLSessionAppcastFetcher(),
                siteBase: URL? = URL(string: "https://cmux.com/whats-new/")) {
        self.cache = cache
        self.bundledDirectories = bundledDirectories
        self.fetcher = fetcher
        self.siteBase = siteBase
    }

    /// `notes` with every media reference replaced by a checked `data:` URL; media that fails a
    /// check is dropped, never passed through as a remote URL.
    @concurrent
    public func inlined(_ notes: ReleaseNotes) async -> ReleaseNotes {
        var notes = notes
        for index in notes.highlights.indices {
            var kept: [ReleaseNotes.Media] = []
            for media in notes.highlights[index].media {
                guard let data = await highlightData(media), let url = Self.dataURL(data) else { continue }
                kept.append(ReleaseNotes.Media(url: url, sha256: media.sha256, kind: media.kind, alt: media.alt))
            }
            notes.highlights[index].media = kept
        }
        if var document = notes.whatsNew {
            for index in document.entries.indices {
                guard let media = document.entries[index].media else { continue }
                let light = await documentData(media.light).flatMap(Self.dataURL)
                let dark = media.dark == media.light ? light : await documentData(media.dark).flatMap(Self.dataURL)
                if let light = light ?? dark, let dark = dark ?? light {
                    document.entries[index].media = WhatsNewDocument.Media(
                        kind: media.kind, light: light.absoluteString, dark: dark.absoluteString, alt: media.alt)
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
    private func highlightData(_ media: ReleaseNotes.Media) async -> Data? {
        let hash = media.sha256.lowercased()
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit), media.url.scheme == "https" else { return nil }
        let cached = cache.appending(path: "sha256-\(hash)")
        // concurrency-allow: @concurrent, never on the main thread; one cached file.
        if let data = try? Data(contentsOf: cached), Self.sha256(data) == hash, Self.kind(of: data) != nil { return data }
        guard let data = try? await fetcher.fetch(media.url), Self.sha256(data) == hash, Self.admits(data) else { return nil }
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

    private func store(_ data: Data, at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Checks

    enum Kind: String {
        case png = "image/png", jpeg = "image/jpeg", gif = "image/gif", webp = "image/webp", mp4 = "video/mp4"
        var isVideo: Bool { self == .mp4 }
    }

    /// The file type from its first bytes (never from a name or a server header).
    static func kind(of data: Data) -> Kind? {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 12 else { return nil }
        if b[0...7] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if b[0...2] == [0xFF, 0xD8, 0xFF] { return .jpeg }
        if b[0...3] == [0x47, 0x49, 0x46, 0x38] { return .gif }
        if b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return .webp }
        if b[4...7] == [0x66, 0x74, 0x79, 0x70] { return .mp4 }
        return nil
    }

    static func admits(_ data: Data) -> Bool {
        guard let kind = kind(of: data) else { return false }
        return data.count <= (kind.isVideo ? maxVideoBytes : maxImageBytes)
    }

    static func dataURL(_ data: Data) -> URL? {
        guard admits(data), let kind = kind(of: data) else { return nil }
        return URL(string: "data:\(kind.rawValue);base64,\(data.base64EncodedString())")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
