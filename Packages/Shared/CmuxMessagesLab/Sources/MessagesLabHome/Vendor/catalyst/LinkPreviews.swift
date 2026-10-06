#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import LinkPresentation
import ImageIO
import UniformTypeIdentifiers

/// Link previews as Messages makes them: `LPMetadataProvider` fetches the
/// page's title, site and image off the main thread; the image is downsampled
/// (ImageIO, at most 600 px wide, its colour profile kept) into the caches
/// directory and the link part points at it. One fetch per URL: results (and
/// failures) are cached in memory and on disk, concurrent requests for the
/// same URL share one fetch, and fetches start only when a message is sent or
/// received (Store.apply), never while scrolling or paging. A fetch that fails
/// or takes longer than `timeout` keeps the domain card (TextParts).
final class LinkPreviews: LinkPreviewFetching {
    static let shared = LinkPreviews()
    var timeout: TimeInterval = 8
    private var cache: [String: LinkMetadata?] = [:]
    private var waiting: [String: [(LinkMetadata) -> Void]] = [:]
    private let dir: URL = {
        // cmux: the app's own caches folder (MessagesLab's would be shared with the MessagesLab app's index).
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "MessagesLab", isDirectory: true)
            .appendingPathComponent("link-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var index: URL { dir.appendingPathComponent("index.json") }

    init() {
        if let d = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([String: Saved].self, from: d) {
            for (k, v) in saved { cache[k] = v.ok ? LinkMetadata(title: v.title, site: v.site, image: v.image) : nil }
        }
    }
    private struct Saved: Codable { var ok: Bool; var title: String?; var site: String?; var image: String? }

    /// cmux: a fetched preview without fetching (nil: not fetched, or it failed). A
    /// HomeStore rebuild maps a link part again; it shows what was already fetched.
    func cached(_ url: String) -> LinkMetadata? { cache[url] ?? nil }

    func fetch(_ url: String, done: @escaping (LinkMetadata) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let hit = cache[url] { if let hit { done(hit) }; return }
        if waiting[url] != nil { waiting[url]!.append(done); return }
        guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http" else { return }
        waiting[url] = [done]
        let provider = LPMetadataProvider()
        provider.timeout = timeout
        provider.startFetchingMetadata(for: u) { [weak self] meta, _ in
            guard let self else { return }
            let site = meta?.url?.host ?? u.host
            let host = site.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            guard let meta else { DispatchQueue.main.async { self.finish(url, nil) }; return }
            let title = meta.title
            let file = self.dir.appendingPathComponent(String(format: "%016llx.png", LinkPreviews.fnv1a(url)))
            let provider = meta.imageProvider ?? meta.iconProvider
            guard let provider else {
                DispatchQueue.main.async { self.finish(url, LinkMetadata(title: title, site: host, image: nil)) }
                return
            }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { tmp, _ in
                var asset: String?
                if let tmp, let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
                   let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                           kCGImageSourceCreateThumbnailWithTransform: true,
                                                                           kCGImageSourceThumbnailMaxPixelSize: 600] as CFDictionary),
                   let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil)
                    if CGImageDestinationFinalize(dest) { asset = file.absoluteString }
                }
                DispatchQueue.main.async { self.finish(url, LinkMetadata(title: title, site: host, image: asset)) }
            }
        }
    }

    /// A stable file name per URL (String.hashValue changes per launch).
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    private func finish(_ url: String, _ meta: LinkMetadata?) {
        cache[url] = .some(meta)
        let cbs = waiting.removeValue(forKey: url) ?? []
        if let meta { cbs.forEach { $0(meta) } }
        save()
    }

    private func save() {
        var out: [String: Saved] = [:]
        for (k, v) in cache { out[k] = Saved(ok: v != nil, title: v?.title, site: v?.site, image: v?.image) }
        if let d = try? JSONEncoder().encode(out) { try? d.write(to: index, options: .atomic) }
    }
}
