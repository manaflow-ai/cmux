import CmuxNextRemoteFetch
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The favicon of each web site a reply, a prompt or a fetch tool row links to (`link.favicons
/// {hosts}`), for the mark the page draws before the link (chips/SiteIcon.tsx). The page loads no
/// image from the network (CSP `img-src data:`), so the host answers each icon as a small PNG data
/// URL. An icon cmux already has from its own browser tabs comes first (``AgentPaneReplyLinks/sites``,
/// no network); else the host asks a public favicon service for the site's icon, as T3 Code does
/// (Lucas 2026-10-29). The service knows icons a site declares only in its page (`rust-lang.org` has
/// no `/favicon.ico`) and those of sites that refuse a direct fetch: 97% of 106 common developer
/// sites against 65% for `/favicon.ico` (outputs/2026-10-29-chat-t3/favicons.md). It learns the host
/// name of each site a chat links, never the link's path or query.
///
/// The host name is reply text an agent wrote, so the fetch is narrow:
/// - only a public DNS name is asked (``publicHost(of:)``): no address literal, single label,
///   local or reserved name, or company host (`*.corp.*`, `*.internal.*`, `*.intranet.*`), and no
///   path, query or port of the link;
/// - through ``GuardedRemoteFetch`` (https only; every address of every hop public, so no local,
///   private or rebinding target; at most 3 redirects, each checked; no cookies, credentials,
///   cache, proxy or referrer), at most ``maximumBytes`` within ``timeout``;
/// - an image answer only (``isImageType(_:)``; the service answers 404 for a site it has no icon
///   for), decoded and drawn again as a PNG of at most ``side`` pixels off the main actor, so bytes
///   that only claim to be an image never reach the page;
/// - `agentPane.images.remote` = `never` fetches nothing (the page keeps its globes).
///
/// Answers, an icon or none, are kept per host, at most ``capacity`` of them; a host is fetched
/// once however many links or requests name it at the same time. The App makes one for all its panes
/// (`AppServices.agentSiteIcons`), so a site is fetched once per app run, not once per chat.
public final class AgentPaneSiteIcons {
    static let maximumBytes = 64 << 10
    static let timeout: Duration = .seconds(5)
    /// Longest side of the PNG the page gets (a 14 pt mark at up to 4x).
    nonisolated static let side = 64
    /// Hosts kept, with or without an icon: as many as a page keeps (chips/siteIcons.ts), so a
    /// page's asks never outrun the host's answers and go back to the service.
    static let capacity = 512
    /// Fetches at once, for all panes.
    static let maximumRunning = 8
    /// How long a site with no icon, or a fetch that failed, stays without one before it is asked
    /// again (the service answers 404 for a site it has none for; a timeout or no network looks the
    /// same, so neither is kept for the app run).
    static let missingFor: Duration = .seconds(600)
    /// The only hosts a favicon fetch may reach: the service, and the image servers it redirects
    /// to (`t0` to `t3.gstatic.com`). A redirect anywhere else is refused.
    nonisolated static let serviceHosts: Set<String> = ["www.google.com", "t0.gstatic.com", "t1.gstatic.com", "t2.gstatic.com",
                                                        "t3.gstatic.com"]
    /// The icon size asked of the service, in pixels (T3 Code's; the mark is 14 pt).
    nonisolated static let serviceSize = 32
    /// The `Accept` of a favicon request: raster types the host decodes (no SVG, which ImageIO
    /// does not draw).
    static let accept = "image/avif,image/webp,image/png,image/x-icon,image/*;q=0.8,*/*;q=0.5"

    private enum Answer {
        case icon(String)
        case missing(since: ContinuousClock.Instant)
    }

    /// The fetch, held to ``serviceHosts``; tests replace its resolver and transport.
    var guarded: GuardedRemoteFetch = {
        var fetch = GuardedRemoteFetch(maximumBytes: AgentPaneSiteIcons.maximumBytes, timeout: AgentPaneSiteIcons.timeout,
                                       accept: AgentPaneSiteIcons.accept)
        fetch.hosts = AgentPaneSiteIcons.serviceHosts
        return fetch
    }()
    private var answers: [String: Answer] = [:]
    /// The kept hosts, oldest first.
    private var order: [String] = []
    /// One fetch per host; each ends within the fetch's timeout and the decode.
    private var running: [String: Task<String?, Never>] = [:]
    /// Fetches past ``maximumRunning`` wait here for a slot, oldest first.
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// The icon of each of `hosts` that has one, by host. `known` holds icons cmux already has
    /// (by host); `fetch` false asks no site.
    func icons(for hosts: [String], known: [String: String], fetch: Bool) async -> [String: String] {
        var out: [String: String] = [:]
        var waits: [(host: String, task: Task<String?, Never>)] = []
        for host in hosts {
            if let icon = known[host] {
                out[host] = icon
                continue
            }
            guard let name = Self.publicHost(of: host) else { continue }
            switch answers[name] {
            case .icon(let icon)?: out[host] = icon
            case .missing(let since)? where ContinuousClock.now - since < Self.missingFor: continue
            case .missing?, nil:
                guard fetch else { continue }
                waits.append((host, load(name)))
            }
        }
        for wait in waits {
            if let icon = await wait.task.value { out[wait.host] = icon }
        }
        return out
    }

    private func load(_ host: String) -> Task<String?, Never> {
        if let task = running[host] { return task }
        let guarded = guarded
        // task-owner: one host's favicon fetch and decode, bounded by the fetch's timeout; it
        // records its answer and leaves `running` when it ends.
        let task = Task { [weak self] () -> String? in
            await self?.slot()
            let icon = await Self.fetchIcon(host, with: guarded)
            self?.leave()
            self?.finish(host, icon)
            return icon
        }
        running[host] = task
        return task
    }

    /// Waits for one of the ``maximumRunning`` fetch slots.
    private func slot() async {
        guard active >= Self.maximumRunning else {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Gives a fetch slot to the oldest waiting fetch, or frees it.
    private func leave() {
        if waiting.isEmpty {
            active -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    private func finish(_ host: String, _ icon: String?) {
        running[host] = nil
        if answers[host] == nil { order.append(host) }
        answers[host] = icon.map(Answer.icon) ?? .missing(since: .now)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            answers[oldest] = nil
        }
    }

    /// The favicon service's icon for `host` as a PNG data URL, or nil when it has none.
    nonisolated static func fetchIcon(_ host: String, with guarded: GuardedRemoteFetch) async -> String? {
        guard let url = serviceURL(host),
              case .success(let response) = await guarded.fetch(url),
              isImageType(response.headers["content-type"]) else { return nil }
        return await AgentPaneSiteIconImage.dataURL(response.body)
    }

    /// The favicon service's address for `host` (a ``publicHost(of:)`` name).
    nonisolated static func serviceURL(_ host: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "www.google.com"
        parts.path = "/s2/favicons"
        parts.queryItems = [URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: String(serviceSize))]
        return parts.url
    }

    /// Whether an answer's `Content-Type` may be an icon: an image other than SVG, a generic binary
    /// (servers often send `.ico` so), or none. A page (`text/html`, a soft 404) is not.
    nonisolated static func isImageType(_ header: String?) -> Bool {
        guard let header else { return true }
        let type = header.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if type.isEmpty || type == "application/octet-stream" { return true }
        return type.hasPrefix("image/") && type != "image/svg+xml"
    }

    /// Names that are never a public site (T3 Code's list, and the local and reserved names).
    nonisolated static let privateSuffixes = ["localhost", "local", "internal", "intranet", "corp", "private", "home", "home.arpa", "lan",
                                              "alt", "test", "example", "invalid", "onion"]
    /// Labels that mark a company's own host anywhere in a public name (`jira.corp.acme.com`): such a
    /// name is never sent to the service.
    nonisolated static let internalLabels: Set<String> = ["corp", "internal", "intranet"]

    /// `host` as the favicon service is asked it: lowercased, without a trailing dot. Nil for
    /// anything but a public DNS name of two or more labels (an address literal, a single label, a
    /// local or reserved name).
    nonisolated static func publicHost(of host: String) -> String? {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253 else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, let last = labels.last else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        }
        // The top level is letters (or an IDN's `xn--`): `10.0.0.1` and other numbers are not names.
        guard last.hasPrefix("xn--") || last.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }), last.count >= 2 else { return nil }
        for suffix in privateSuffixes where name == suffix || name.hasSuffix("." + suffix) {
            return nil
        }
        if labels.contains(where: internalLabels.contains) { return nil }
        return name
    }
}

/// A fetched favicon as the page may draw it: decoded (PNG, JPEG, GIF, WebP, ICO or BMP; the
/// sharpest frame of an `.ico`), drawn again in sRGB at most ``AgentPaneSiteIcons/side`` pixels
/// and written as a PNG data URL.
nonisolated struct AgentPaneSiteIconImage {
    static let types: Set<String> = [
        UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier,
        UTType.ico.identifier, UTType.bmp.identifier,
    ]
    /// Largest frame side decoded: a favicon is never bigger, and a small file that claims a huge
    /// image (a decompression bomb) is refused before it is drawn.
    static let maximumFrameSide = 1024

    /// The PNG data URL of `data`, decoded off the main actor; nil when it is no icon.
    @concurrent static func dataURL(_ data: Data) async -> String? {
        png(data)
    }

    static func png(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, types.contains(type) else { return nil }
        // An `.ico` holds several sizes: the largest draws the sharpest mark.
        var best: (index: Int, side: Int)?
        for index in 0..<min(CGImageSourceGetCount(source), 16) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= maximumFrameSide, height <= maximumFrameSide else { continue }
            let side = max(width, height)
            if let current = best, current.side >= side { continue }
            best = (index, side)
        }
        guard let best else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: AgentPaneSiteIcons.side,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, best.index, options as CFDictionary) else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard var normalized = context.makeImage() else { return nil }
        if isDarkOnClear(context), let plated = plated(normalized, colorSpace: colorSpace) { normalized = plated }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, normalized, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/png;base64," + (output as Data).base64EncodedString()
    }

    /// Whether a drawn icon is a dark mark on a clear ground (`doc.rust-lang.org`'s black gear), which
    /// a dark theme would hide: a fifth or more of it clear, and its solid pixels dark on average.
    static func isDarkOnClear(_ context: CGContext) -> Bool {
        guard let data = context.data, context.bitsPerPixel == 32 else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
        var clear = 0, solid = 0
        var light = 0.0
        for row in 0..<context.height {
            for column in 0..<context.width {
                let at = row * context.bytesPerRow + column * 4
                let alpha = Double(pixels[at + 3])
                guard alpha >= 128 else { clear += 1; continue }
                solid += 1
                // Premultiplied: divide the alpha out, then Rec. 709 luma.
                let red = Double(pixels[at]) / alpha, green = Double(pixels[at + 1]) / alpha, blue = Double(pixels[at + 2]) / alpha
                light += 0.2126 * red + 0.7152 * green + 0.0722 * blue
            }
        }
        let total = context.width * context.height
        guard solid > 0, total > 0 else { return false }
        return Double(clear) >= Double(total) * 0.2 && light / Double(solid) < 0.25
    }

    /// The icon on a white rounded plate, as browsers draw a dark favicon in a dark theme; on a light
    /// theme the plate does not show.
    static func plated(_ image: CGImage, colorSpace: CGColorSpace) -> CGImage? {
        let side = CGFloat(max(image.width, image.height))
        guard let context = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let plate = CGRect(x: 0, y: 0, width: side, height: side)
        context.addPath(CGPath(roundedRect: plate, cornerWidth: side * 0.22, cornerHeight: side * 0.22, transform: nil))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
        context.fillPath()
        context.draw(image, in: plate.insetBy(dx: side * 0.12, dy: side * 0.12))
        return context.makeImage()
    }
}
