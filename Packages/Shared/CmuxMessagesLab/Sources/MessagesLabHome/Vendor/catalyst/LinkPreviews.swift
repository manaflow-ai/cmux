#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import ImageIO
import UniformTypeIdentifiers

/// Link previews: the page's title, site and image, fetched once per URL.
/// URLSession on a background queue reads the page's Open Graph / Twitter /
/// <title> tags and the image; ImageIO downsamples the image (at most 600 px
/// wide, its colour profile kept) into the caches directory and the link part
/// points at it. Every network request, including redirects and the image,
/// stays inside `GuardedFetcher`; there is no WebKit or LinkPresentation
/// fallback that can leave its address checks. Results (and failures) are
/// cached in memory and on disk, concurrent requests for one URL share one
/// fetch, and fetches start only when a message is sent or received
/// (Store.apply), never while scrolling or paging. A failure or a `timeout`
/// gives `done(nil)`: the caller shows the domain card.
/// cmux: main-actor, as its `fetch` precondition says (an isolated conformance); the page parsers
/// are nonisolated (they run on the fetcher's queue; p10-stability-040).
@MainActor
final class LinkPreviews: @MainActor LinkPreviewFetching {
    static let shared = LinkPreviews()
    var timeout: TimeInterval = 8
    private var cache: [String: LinkMetadata?] = [:]
    private var waiting: [String: [(LinkMetadata?) -> Void]] = [:]
    /// Fetches running now (tests).
    var inFlight: Int { waiting.count }
    private let dir: URL = {
        // cmux: the app's own caches folder (MessagesLab's would be shared with the MessagesLab app's index).
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "MessagesLab", isDirectory: true)
            .appendingPathComponent("link-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var index: URL { dir.appendingPathComponent("index.json") }

    /// A "no title" answer is kept this long (a later fix or a page change can then get one).
    nonisolated static let negativeTTL: TimeInterval = 24 * 3600
    private var negativeAt: [String: Double] = [:]
    init() {
        if let d = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([String: Saved].self, from: d) {
            let now = Date().timeIntervalSince1970
            for (k, v) in saved {
                if v.ok { cache.updateValue(.some(LinkMetadata(title: v.title, site: v.site, image: v.image)), forKey: k) }
                else if let at = v.at, now - at < LinkPreviews.negativeTTL { cache.updateValue(Optional<LinkMetadata>.none, forKey: k); /* a known failure: the stored value is nil */ negativeAt.updateValue(at, forKey: k) }
            }
        }
    }
    private struct Saved: Codable { var ok: Bool; var title: String?; var site: String?; var image: String?; var at: Double? }

    /// a fetched preview without fetching (nil: not fetched, or it failed). A
    /// HomeStore rebuild maps a link part again; it shows what was already fetched.
    func cached(_ url: String) -> LinkMetadata? { cache[url] ?? nil }

    func fetch(_ url: String, done: @escaping (LinkMetadata?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let hit = cache[url] {
            done(hit)
            return
        }
        if waiting[url] != nil { waiting[url]?.append(done); return } // no force unwrap
        guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http", LinkGuard.checkURL(u) != .scheme else { done(nil); return }
        waiting[url] = [done]
        let file = dir.appendingPathComponent(String(format: "%016llx.png", LinkPreviews.fnv1a(url)))
        // Every request goes through LinkGuard (LinkGuard.swift): public addresses
        // only, redirects re-checked, an ephemeral session, size caps.
        let fetcher = GuardedFetcher.shared
        fetcher.timeout = timeout
        fetcher.get(u, limit: LinkGuard.htmlLimit, html: true) { [weak self] res in
            guard let self else { return }
            guard case let .success(page) = res,
                  let html = String(data: page.data, encoding: .utf8) ?? String(data: page.data, encoding: .isoLatin1) else {
                let refusal: LinkGuard.Refusal? = { if case let .failure(r) = res { return r }; return nil }()
                DispatchQueue.main.async { self.lastRefusal[url] = refusal; self.finish(url, nil) }; return
            }
            let base = page.url
            let tags = LinkPreviews.metaTags(html)
            let title = (tags["og:title"] ?? tags["twitter:title"] ?? LinkPreviews.titleTag(html)).map { LinkPreviews.stripSite($0, tags["og:site_name"]) }
            let site = base.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }   // Messages shows the domain
            guard title != nil else { DispatchQueue.main.async { self.finish(url, nil) }; return }
            let imageURL = (tags["og:image"] ?? tags["og:image:url"] ?? tags["twitter:image"]).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            guard let imageURL else {
                DispatchQueue.main.async { self.finish(url, LinkMetadata(title: title, site: site, image: nil)) }; return
            }
            fetcher.get(imageURL, limit: LinkGuard.imageLimit, html: false) { ires in
                var asset: String?
                if case let .success(img) = ires, let src = CGImageSourceCreateWithData(img.data as CFData, nil),
                   let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 600] as CFDictionary),
                   let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cg, nil)
                    if CGImageDestinationFinalize(dest) { asset = file.absoluteString }
                }
                DispatchQueue.main.async { self.finish(url, LinkMetadata(title: title, site: site, image: asset)) }
            }
        }
    }

    /// Why a URL's preview was refused (tests).
    var lastRefusal: [String: LinkGuard.Refusal] = [:]

    /// `<meta property|name="…" content="…">` (either attribute order), entities decoded.
    nonisolated static func metaTags(_ html: String) -> [String: String] {
        var out: [String: String] = [:]
        // no try! ; a pattern that fails to compile reads no tags.
        guard let re = try? NSRegularExpression(pattern: "<meta\\s+[^>]*>", options: [.caseInsensitive]),
              let key = try? NSRegularExpression(pattern: "(?:property|name)\\s*=\\s*[\"']([^\"']+)[\"']", options: [.caseInsensitive]),
              let val = try? NSRegularExpression(pattern: "content\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", options: [.caseInsensitive])
        else { return out }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: min(ns.length, 400_000))) {
            // cmux: checked substrings (a group that took no part is {NSNotFound, 0}, p10-stability-169)
            guard let found = ns.checkedSubstring(m.range) else { continue }
            let tag = found as NSString
            guard let k = key.firstMatch(in: tag as String, range: NSRange(location: 0, length: tag.length)),
                  let v = val.firstMatch(in: tag as String, range: NSRange(location: 0, length: tag.length)),
                  let name = tag.checkedSubstring(k.range(at: 1))?.lowercased() else { continue }
            let r = v.range(at: 2).location != NSNotFound ? v.range(at: 2) : v.range(at: 3)
            guard let raw = tag.checkedSubstring(r) else { continue }
            let content = decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.keys.contains(name), !content.isEmpty { out.updateValue(content, forKey: name) }
        }
        return out
    }
    /// "GitHub - manaflow-ai/cmux: …" shows as "manaflow-ai/cmux: …" (Messages,
    /// link-and-text take): a leading or trailing site name with a separator goes.
    nonisolated static func stripSite(_ t: String, _ site: String?) -> String {
        guard let site, !site.isEmpty else { return t }
        for sep in [" - ", " | ", " · ", " — ", ": "] {
            if t.hasPrefix(site + sep) { return String(t.dropFirst(site.count + sep.count)) }
            if t.hasSuffix(sep + site) { return String(t.dropLast(site.count + sep.count)) }
        }
        return t
    }

    nonisolated static func titleTag(_ html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<title[^>]*>([^<]*)</title>", options: [.caseInsensitive]),
              let m = re.firstMatch(in: html, range: NSRange(location: 0, length: min((html as NSString).length, 400_000))) else { return nil }
        guard let raw = (html as NSString).checkedSubstring(m.range(at: 1)) else { return nil } // cmux: checked
        let t = decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    nonisolated static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var t = s
        for (k, v) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
    }

    /// A stable file name per URL (String.hashValue changes per launch).
    nonisolated static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(truncatingIfNeeded: b)) &* 0x100000001b3 /* a byte widens exactly */ }
        return h
    }

    private func finish(_ url: String, _ meta: LinkMetadata?) {
        cache.updateValue(meta, forKey: url) /* the value type is LinkMetadata? (nil: a failed fetch) */
        if meta?.title == nil { negativeAt[url] = Date().timeIntervalSince1970 }
        let cbs = waiting.removeValue(forKey: url) ?? []
        cbs.forEach { $0(meta) }
        save()
    }

    // MARK: Visible guarded refresh

    /// A guarded result for a historical outgoing row after its first projection; the host
    /// dispatches `.linkMetadata` with it.
    var onLateMetadata: ((String, LinkMetadata) -> Void)?
    /// Outgoing link rows on screen with no title yet (the host passes them on scroll and after a
    /// change): a cached title updates the row; otherwise the normal guarded parser runs once.
    func consider(_ urls: [String]) {
        for url in urls {
            if let hit = cache[url], let meta = hit, meta.title != nil { onLateMetadata?(url, meta); continue }
            if !cache.keys.contains(url), !waiting.keys.contains(url) {
                fetch(url) { [weak self] meta in
                    if let meta, meta.title != nil { self?.onLateMetadata?(url, meta) }
                }
            }
        }
    }

    /// The removed system fallback is never an allowed transport, whatever the guarded result.
    nonisolated static func fallbackAllowed(_: LinkGuard.Refusal?) -> Bool { false }

    private func save() {
        var out: [String: Saved] = [:]
        for (k, v) in cache {
            if let v, v.title != nil { out.updateValue(Saved(ok: true, title: v.title, site: v.site, image: v.image, at: nil), forKey: k) }
            else { out.updateValue(Saved(ok: false, title: nil, site: nil, image: nil, at: negativeAt[k] ?? Date().timeIntervalSince1970), forKey: k) }
        }
        if let d = try? JSONEncoder().encode(out) { try? d.write(to: index, options: .atomic) }
    }
}
