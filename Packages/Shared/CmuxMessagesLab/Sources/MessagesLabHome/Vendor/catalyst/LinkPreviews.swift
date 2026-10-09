#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import ImageIO
import LinkPresentation
import UniformTypeIdentifiers

/// Link previews: the page's title, site and image, fetched once per URL.
/// URLSession on a background queue reads the page's Open Graph / Twitter /
/// <title> tags (what LinkPresentation reads) and the image; ImageIO downsamples
/// the image (at most 600 px wide, its colour profile kept) into the caches
/// directory and the link part points at it. Nothing runs on the main thread
/// until the one hand-off with the result: LPMetadataProvider loaded the page
/// in WebKit and woke the main run loop about 44 times a second for the whole
/// fetch (89 wake-ups and 82 ms of main CPU in 2 s, `--wake-probe`), which the
/// idle self-test caught. Results (and failures) are cached in memory and on
/// disk, concurrent requests for one URL share one fetch, and fetches start
/// only when a message is sent or received (Store.apply), never while
/// scrolling or paging. A failure or a `timeout` gives `done(nil)`: the
/// caller shows the domain card.
final class LinkPreviews: LinkPreviewFetching {
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
    static let negativeTTL: TimeInterval = 24 * 3600
    private var negativeAt: [String: Double] = [:]
    init() {
        if let d = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([String: Saved].self, from: d) {
            let now = Date().timeIntervalSince1970
            for (k, v) in saved {
                if v.ok { cache[k] = .some(LinkMetadata(title: v.title, site: v.site, image: v.image)) }
                else if let at = v.at, now - at < LinkPreviews.negativeTTL { cache[k] = .some(nil); negativeAt[k] = at }
            }
        }
    }
    private struct Saved: Codable { var ok: Bool; var title: String?; var site: String?; var image: String?; var at: Double? }

    /// cmux: a fetched preview without fetching (nil: not fetched, or it failed). A
    /// HomeStore rebuild maps a link part again; it shows what was already fetched.
    func cached(_ url: String) -> LinkMetadata? { cache[url] ?? nil }

    func fetch(_ url: String, done: @escaping (LinkMetadata?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let hit = cache[url] {
            done(hit)
            if hit?.title == nil { enqueueFallback(url) }
            return
        }
        if waiting[url] != nil { waiting[url]?.append(done); return } // cmux: no force unwrap
        guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http" else { done(nil); return }
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
    static func metaTags(_ html: String) -> [String: String] {
        var out: [String: String] = [:]
        // cmux: no try! (crash program); a pattern that fails to compile reads no tags.
        guard let re = try? NSRegularExpression(pattern: "<meta\\s+[^>]*>", options: [.caseInsensitive]),
              let key = try? NSRegularExpression(pattern: "(?:property|name)\\s*=\\s*[\"']([^\"']+)[\"']", options: [.caseInsensitive]),
              let val = try? NSRegularExpression(pattern: "content\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", options: [.caseInsensitive])
        else { return out }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: min(ns.length, 400_000))) {
            let tag = ns.substring(with: m.range) as NSString
            guard let k = key.firstMatch(in: tag as String, range: NSRange(location: 0, length: tag.length)),
                  let v = val.firstMatch(in: tag as String, range: NSRange(location: 0, length: tag.length)) else { continue }
            let name = tag.substring(with: k.range(at: 1)).lowercased()
            let r = v.range(at: 2).location != NSNotFound ? v.range(at: 2) : v.range(at: 3)
            let content = decode(tag.substring(with: r)).trimmingCharacters(in: .whitespacesAndNewlines)
            if out[name] == nil, !content.isEmpty { out[name] = content }
        }
        return out
    }
    /// "GitHub - manaflow-ai/cmux: …" shows as "manaflow-ai/cmux: …" (Messages,
    /// link-and-text take): a leading or trailing site name with a separator goes.
    static func stripSite(_ t: String, _ site: String?) -> String {
        guard let site, !site.isEmpty else { return t }
        for sep in [" - ", " | ", " · ", " — ", ": "] {
            if t.hasPrefix(site + sep) { return String(t.dropFirst(site.count + sep.count)) }
            if t.hasSuffix(sep + site) { return String(t.dropLast(site.count + sep.count)) }
        }
        return t
    }

    static func titleTag(_ html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<title[^>]*>([^<]*)</title>", options: [.caseInsensitive]),
              let m = re.firstMatch(in: html, range: NSRange(location: 0, length: min((html as NSString).length, 400_000))) else { return nil }
        let t = decode((html as NSString).substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var t = s
        for (k, v) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
    }

    /// A stable file name per URL (String.hashValue changes per launch).
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    private func finish(_ url: String, _ meta: LinkMetadata?) {
        cache[url] = .some(meta)
        if meta?.title == nil { negativeAt[url] = Date().timeIntervalSince1970 }
        let cbs = waiting.removeValue(forKey: url) ?? []
        cbs.forEach { $0(meta) }
        save()
        // No title from the page's tags, and the guard did not refuse the URL: the
        // LinkPresentation fallback may try (pages that build their tags in script).
        // It runs only for a link the local user sent (`isOnScreen`: an outgoing row
        // on screen, from the model): LinkPresentation loads redirects and
        // sub-resources outside LinkGuard, so it never runs for a received link.
        if meta?.title == nil, LinkPreviews.fallbackAllowed(lastRefusal[url]) { enqueueFallback(url) }
    }

    // MARK: LinkPresentation fallback (bounded)

    /// True when an OUTGOING row (sent by the local user: the model's outgoing flag)
    /// shows this link on screen. The host sets it; the fallback runs only then.
    var isOnScreen: (String) -> Bool = { _ in false }
    /// A fallback result after the first answer (`done` already ran): the host
    /// dispatches `.linkMetadata` with it.
    var onLateMetadata: ((String, LinkMetadata) -> Void)?
    private(set) var fallbackQueue: [String] = []
    /// Outgoing link rows on screen with no title yet (the host passes them on
    /// scroll and after a change): a cached title updates the row; otherwise the
    /// fallback may run once a launch. Works for rows loaded from the store.
    func consider(_ urls: [String]) {
        for url in urls {
            if let hit = cache[url], let meta = hit, meta.title != nil { onLateMetadata?(url, meta); continue }
            if cache[url] == nil && waiting[url] == nil { fetch(url) { _ in } }   // the og path first
            else if waiting[url] == nil { enqueueFallback(url) }
        }
    }
    private var fallbackDone: Set<String> = []
    private(set) var fallbackRunning: String?
    /// Every fallback run: URL, seconds, title or nil (tests and the self-test report).
    private(set) var fallbackLog: [String] = []
    private var fallbackStart = Date()
    private var provider: LPMetadataProvider?
    /// Only when the guard let the URL through (a network failure or no tags), never
    /// after a refusal (an address, a name, a port, a redirect).
    static func fallbackAllowed(_ r: LinkGuard.Refusal?) -> Bool {
        switch r { case nil, .network(_)?, .tooLarge?: return true; default: return false }
    }
    private func enqueueFallback(_ url: String) {
        guard !fallbackDone.contains(url), !fallbackQueue.contains(url), fallbackRunning != url else { return }
        fallbackQueue.append(url)
        if fallbackQueue.count > 64 { fallbackQueue.removeFirst() }   // received links wait here, never run
        visibilityChanged()
    }
    /// Event-driven: the host calls it when rows scroll in or out; the next queued
    /// URL whose row is on screen starts, one at a time.
    func visibilityChanged() {
        guard fallbackRunning == nil, let i = fallbackQueue.firstIndex(where: isOnScreen) else { return }
        runFallback(fallbackQueue.remove(at: i))
    }
    /// Runs one LinkPresentation fetch (WebKit: about 44 main run-loop wake-ups a
    /// second while it runs; none after). Tests call it directly.
    func runFallback(_ url: String) {
        guard fallbackRunning == nil, isOnScreen(url), let u = URL(string: url) else { return }
        fallbackRunning = url
        fallbackStart = Date()
        fallbackDone.insert(url)
        let file = dir.appendingPathComponent(String(format: "%016llx-lp.png", LinkPreviews.fnv1a(url)))
        GuardedFetcher.shared.queue.addOperation { [weak self] in
            let refusal = LinkGuard.check(u)        // the guard again, off main
            DispatchQueue.main.async {
                guard let self else { return }
                guard refusal == nil else { self.fallbackFinished(url, nil); return }
                let p = LPMetadataProvider()
                self.provider = p
                p.timeout = self.timeout
                p.startFetchingMetadata(for: u) { m, _ in
                    guard let m, let title = m.title else { DispatchQueue.main.async { self.fallbackFinished(url, nil) }; return }
                    let host = (m.url ?? u).host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
                    guard let ip = m.imageProvider else {
                        DispatchQueue.main.async { self.fallbackFinished(url, LinkMetadata(title: title, site: host, image: nil)) }; return
                    }
                    ip.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { tmp, _ in
                        var asset: String?
                        if let tmp, let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
                           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                                  kCGImageSourceCreateThumbnailWithTransform: true,
                                                                                  kCGImageSourceThumbnailMaxPixelSize: 600] as CFDictionary),
                           let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) {
                            CGImageDestinationAddImage(dest, cg, nil)
                            if CGImageDestinationFinalize(dest) { asset = file.absoluteString }
                        }
                        DispatchQueue.main.async { self.fallbackFinished(url, LinkMetadata(title: title, site: host, image: asset)) }
                    }
                }
            }
        }
    }
    private func fallbackFinished(_ url: String, _ meta: LinkMetadata?) {
        provider = nil
        fallbackLog.append("\(url) \(String(format: "%.1f", Date().timeIntervalSince(fallbackStart))) s \(meta?.title ?? "no title")")
        if let meta {
            cache[url] = .some(meta)
            negativeAt[url] = nil
            save()
            onLateMetadata?(url, meta)
        }
        // LPMetadataProvider keeps its timeout timer after it answers (cancel does not
        // end it): one main run-loop wake-up `timeout` s after the start. The fallback
        // counts as running until then (one at a time includes that tail), so the
        // next one never stacks another timer and "finished" means no work is left.
        let left = fallbackStart.addingTimeInterval(timeout + 0.1).timeIntervalSinceNow
        guard left > 0 else { release(); return }
        let t = Timer(timeInterval: left, repeats: false) { [weak self] _ in self?.release() }
        RunLoop.main.add(t, forMode: .common)
    }
    private func release() {
        fallbackRunning = nil
        visibilityChanged()
    }

    private func save() {
        var out: [String: Saved] = [:]
        for (k, v) in cache {
            if let v, v.title != nil { out[k] = Saved(ok: true, title: v.title, site: v.site, image: v.image, at: nil) }
            else { out[k] = Saved(ok: false, title: nil, site: nil, image: nil, at: negativeAt[k] ?? Date().timeIntervalSince1970) }
        }
        if let d = try? JSONEncoder().encode(out) { try? d.write(to: index, options: .atomic) }
    }
}
