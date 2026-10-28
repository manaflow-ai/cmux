#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import ImageIO
import CmuxSafeConcurrency // cmux: Mutex (p10-stability-055)
import os

/// Decoded images for row drawing (Images.load), bounded by bytes, and image sizes from
/// metadata (no decode). shared/LONG-MESSAGES.md, media-heavy conversations.
/// - A source wider or taller than `maxPixels` is decoded downsampled with ImageIO
///   (never full resolution in memory). Smaller sources take the previous path
///   unchanged (same pixels).
/// - Thread safe: the row bitmap queue decodes; the main thread asks `isCached`
///   before it draws a row itself (a row whose image is not decoded waits for its
///   off-main bitmap, at its final size from metadata, so no height changes).
/// cmux: checked `Sendable` (p10-stability-055): the images (as `HomeShared` values), sizes, budget and
/// counters are one lock state (they were vars under an NSLock in an unchecked class); decoding runs
/// outside the lock, as before.
final class MediaCache: Sendable { // memory: consumer via MessagesLabMemoryConsumer (CmuxNextHome)
    static let shared = MediaCache()
    /// Rows draw media at most 500 pt wide at 3x (map snapshots); photos at most 300 pt.
    static let maxPixels = 2048
    /// cmux: `--image-cache-mb` in bytes, the lab's bench flag: it keeps the cap over the host's share
    /// (`setBudget(bytes:)`, p07-memory-081); a trim still frees.
    static let labBudget: Int? = {
        let a = ProcessInfo.processInfo.arguments
        let mb = a.firstIndex(of: "--image-cache-mb").flatMap { a.dropFirst($0 + 1).first }.flatMap { Int.init($0) } // no index math
        return mb.map { min(max($0, 1), 1 << 20) << 20 } // a huge value cannot overflow the shift
    }()
    /// cmux: the cap until the host sizes the cache, without the flag (MessagesLab's 96 MB).
    static let defaultBudget = 96 << 20
    private struct Entry: Sendable { var image: HomeShared<UIImage>; var bytes: Int; var tick: Int }
    private struct State: Sendable {
        var budget: Int = MediaCache.labBudget ?? MediaCache.defaultBudget
        var map: [String: Entry] = [:]
        var sizes: [String: CGSize] = [:]
        var tick = 0
        var bytes = 0
        // Stats (bench).
        var decodes = 0, downsampled = 0, inFlight = 0, maxInFlight = 0, evicted = 0
        var decodeMsTotal = 0.0, decodeMsMax = 0.0
    }
    // Lock carve-out: the row bitmap queue and main look up and store decoded images; no decode under the lock.
    private let state = Mutex(State())
    var budget: Int {
        get { state.withLock { $0.budget } }
        set { state.withLock { $0.budget = newValue } }
    }
    var bytes: Int { state.withLock { $0.bytes } }

    /// cmux: the host's cap (p07-memory-081); `--image-cache-mb` keeps its own. Lowering it frees nothing: the next
    /// store trims to it.
    func setBudget(bytes: Int) {
        let cap = MediaCache.labBudget ?? max(0, bytes)
        state.withLock { $0.budget = cap }
    }

    /// cmux: frees the least recently drawn images until at most `fraction` of the bytes held now remain (0 frees
    /// every one), off main (p07-memory-081). A row on screen keeps the bitmap it drew; its next draw decodes again.
    func trim(toFraction fraction: Double) {
        let freed = state.withLock { s -> [HomeShared<UIImage>] in
            let target = s.bytes.trimTarget(fraction)
            var freed: [HomeShared<UIImage>] = []
            guard s.bytes > target else { return freed }
            for (k, e) in s.map.sorted(by: { $0.value.tick < $1.value.tick }) {
                if s.bytes <= target { break }
                s.map.removeValue(forKey: k); s.bytes -= e.bytes; freed.append(e.image); s.evicted += 1
            }
            return freed
        }
        if !freed.isEmpty { Reclaimer.release(bitmaps: freed) }
    }

    func cached(_ key: String) -> UIImage? {
        state.withLock { s -> HomeShared<UIImage>? in
            guard var e = s.map[key] else { return nil }
            s.tick += 1
            e.tick = s.tick
            s.map.updateValue(e, forKey: key) // dictionary write
            return e.image
        }?.value
    }
    func isCached(_ key: String) -> Bool { state.withLock { $0.map.keys.contains(key) } }

    func store(_ key: String, _ img: UIImage) {
        let b = img.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        let image = HomeShared(img)
        let freed = state.withLock { s -> [HomeShared<UIImage>] in
            if let old = s.map[key] { s.bytes -= old.bytes }
            s.tick += 1
            s.map.updateValue(Entry(image: image, bytes: b, tick: s.tick), forKey: key) // dictionary write
            s.bytes += b
            var freed: [HomeShared<UIImage>] = []
            if s.bytes > s.budget {
                for (k, e) in s.map.sorted(by: { $0.value.tick < $1.value.tick }) {
                    if s.bytes <= s.budget * 4 / 5 { break }
                    s.map.removeValue(forKey: k); s.bytes -= e.bytes; freed.append(e.image); s.evicted += 1
                }
            }
            return freed
        }
        if !freed.isEmpty { Reclaimer.release(bitmaps: freed) }
    }

    /// cmux: a hidden transcript released its rows (MessagesWindowView.releaseRows): the decoded images of `refs` at
    /// `scale` (Images.load's keys) go, freed off main.
    func evict(refs: Set<String>, scale: CGFloat) {
        guard !refs.isEmpty else { return }
        let at = "@" + String(describing: scale)
        let freed = state.withLock { s -> [HomeShared<UIImage>] in
            var freed: [HomeShared<UIImage>] = []
            for ref in refs {
                guard let e = s.map.removeValue(forKey: ref + at) else { continue }
                s.bytes -= e.bytes
                freed.append(e.image)
            }
            return freed
        }
        if !freed.isEmpty { Reclaimer.release(bitmaps: freed) }
    }

    /// Pixel size from the file's metadata (no decode), cached.
    func pixelSize(_ url: URL) -> CGSize? {
        let k = url.absoluteString
        if let s = state.withLock({ $0.sizes[k] }) { return s }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p.value(for: kCGImagePropertyPixelWidth) as? NSNumber)?.doubleValue, // dictionary reads
              let h = (p.value(for: kCGImagePropertyPixelHeight) as? NSNumber)?.doubleValue else { return nil }
        let orient = (p.value(for: kCGImagePropertyOrientation) as? NSNumber)?.intValue ?? 1
        let s = orient >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        state.withLock { $0.sizes[k] = s }
        return s
    }

    /// Decode a raster asset at `assetScale` points per pixel: downsampled above `maxPixels`.
    func decode(_ url: URL, scale: CGFloat) -> UIImage? {
        let t0 = CACurrentMediaTime()
        state.withLock { s in s.inFlight += 1; s.maxInFlight = max(s.maxInFlight, s.inFlight) }
        defer {
            let ms = (CACurrentMediaTime() - t0) * 1000
            state.withLock { s in s.inFlight -= 1; s.decodes += 1; s.decodeMsTotal += ms; s.decodeMsMax = max(s.decodeMsMax, ms) }
        }
        if let px = pixelSize(url), max(px.width, px.height) > CGFloat(MediaCache.maxPixels),
           let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceShouldCacheImmediately: true,
               kCGImageSourceThumbnailMaxPixelSize: MediaCache.maxPixels] as CFDictionary) {
            state.withLock { $0.downsampled += 1 }
            // The point size keeps the aspect; callers size rows from `pixelSize`, not from this image.
            return UIImage(cgImage: cg, scale: scale, orientation: .up)
        }
        guard let data = try? Data(contentsOf: url), let raw = UIImage(data: data), let cg = raw.cgImage else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up).preparingForDisplay() ?? UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    var count: Int { state.withLock { $0.map.count } }
    var stats: [String: Any] {
        let s = state.withLock { $0 }
        return ["imageCacheMB": Double(s.bytes / 10_486) / 100, "imageCacheBudgetMB": s.budget >> 20, "imagesCached": s.map.count,
                "decodes": s.decodes, "downsampled": s.downsampled,
                "decodeMsMean": s.decodes > 0 ? (s.decodeMsTotal / Double(s.decodes) * 10).rounded() / 10 : 0,
                "decodeMsMax": (s.decodeMsMax * 10).rounded() / 10, "maxDecodesInFlight": s.maxInFlight, "evicted": s.evicted]
    }
}

extension Images {
    /// Pixel size of an asset from metadata (rows size from this, so a downsampled or
    /// not yet decoded image never changes a row's height).
    static func pixelSize(_ ref: String) -> CGSize? { MediaCache.shared.pixelSize(Fixtures.assetURL(ref)) }

    /// The main thread may draw this row itself outside a send: rows that draw an image do
    /// not qualify (a decode is 10-90 ms, and scaling a decoded photo into the row about
    /// 10 ms); they render on the row bitmap queue at their final size.
    static func ready(_ spec: RowSpec) -> Bool {
        guard case let .part(p) = spec.kind else {
            // A thread preview that draws a photo scales it into the row (about 8 ms): off main too.
            if case let .threadPreview(pv) = spec.kind, previewRef(pv.part) != nil { return false }
            return true
        }
        switch p.part {
        case let .attachment(a) where a.kind == "image" || a.kind == "video": return false
        case .link(_, _, _, _?, _): return false
        default: return true
        }
    }
    private static func previewRef(_ p: Part?) -> String? {
        switch p {
        case let .attachment(a)?: return a.kind == "video" ? (a.poster ?? a.asset) : a.asset
        case let .link(_, _, _, image?, _)?: return image
        default: return nil
        }
    }
    static func isCached(_ ref: String) -> Bool { MediaCache.shared.isCached(ref + "@" + String(describing: Fixture.renderScale)) }
}

extension VectorAsset {
    /// cmux: rows ask on the main thread and the render queues: the lock owns the cache.
    private static let siblings = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])
    /// Whether `name.png` has a `name.svg` beside it (cached file check, no parse).
    static func hasSibling(_ ref: String) -> Bool {
        guard !ref.hasPrefix("file:"), ref.hasSuffix(".png") else { return false }
        if let v = siblings.withLock({ $0[ref] }) { return v }
        let v = FileManager.default.fileExists(atPath: Fixtures.assetURL(String(ref.dropLast(4)) + ".svg").path)
        siblings.withLock { $0[ref] = v }
        return v
    }
}

// MARK: Pop-in: tiny thumbnails, placeholders and scroll-direction prefetch

extension MediaCache {
    /// 48 px thumbnails (the file's embedded thumbnail when it has one, else a subsampled
    /// decode), main-thread cache, LRU-free: about 9 KB each, bounded by count.
    static let thumbQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        q.name = "media.thumbs"
        return q
    }()
    // Main thread only; only the decode runs on thumbQueue.
    private static var thumbs: [String: CGImage] = [:]
    private static var thumbOrder: [String] = []
    /// cmux: pending refs with every waiting request's completion, kept on main (they hold layers; only the ref
    /// crosses to thumbQueue).
    private static var thumbPending: [String: [() -> Void]] = [:]
    static var thumbsMade = 0, thumbMsTotal = 0.0, thumbMsMax = 0.0
    static let thumbCapacity = 2000

    /// Main thread.
    static func thumb(_ ref: String) -> CGImage? { thumbs[ref] }

    /// Main thread: make the thumbnail off main if it is missing. `done` runs on main.
    static func requestThumb(_ ref: String, _ done: (() -> Void)? = nil) {
        guard thumbs[ref] == nil else { return }
        if thumbPending[ref] != nil { // already decoding: this request waits for the same thumbnail
            if let done { thumbPending[ref]?.append(done) }
            return
        }
        thumbPending[ref] = done.map { [$0] } ?? []
        let url = Fixtures.assetURL(ref)
        thumbQueue.addOperation {
            let t0 = CACurrentMediaTime()
            let img = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary).flatMap { src in
                CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 48] as CFDictionary)
            }
            let ms = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.async {
                let done = thumbPending.removeValue(forKey: ref) ?? []
                thumbsMade += 1; thumbMsTotal += ms; thumbMsMax = max(thumbMsMax, ms)
                guard let img else { return }
                thumbs[ref] = img
                thumbOrder.append(ref)
                if thumbOrder.count > thumbCapacity + 200 {
                    for k in thumbOrder.prefix(thumbOrder.count - thumbCapacity) { thumbs[k] = nil }
                    thumbOrder.removeFirst(thumbOrder.count - thumbCapacity)
                }
                done.forEach { $0() }
            }
        }
    }
}

/// A media row whose bitmap is not ready shows its thumbnail magnified on the cell's bitmap
/// layer (linear filtering blurs it), clipped to the bubble's corners, at the final body
/// rect (sizes come from metadata): no drawing on main, no height change.
enum MediaPlaceholder {
    static let name = "media.placeholder"
    static func ref(_ spec: RowSpec) -> String? {
        guard case let .part(p) = spec.kind else { return nil }
        switch p.part {
        case let .attachment(a) where a.kind == "image" || a.kind == "video": return a.kind == "video" ? (a.poster ?? a.asset) : a.asset
        case let .link(_, _, _, image?, _): return image
        default: return nil
        }
    }
    /// Main thread, inside the cell's transaction. Returns false for rows without media.
    static let enabled = !ProcessInfo.processInfo.arguments.contains("--no-placeholder")
    @discardableResult
    static func show(_ layer: CALayer, _ spec: RowSpec) -> Bool {
        guard enabled, let ref = ref(spec) else { return false }
        var body = RowDraw.bodyRect(spec)
        if case let .part(p) = spec.kind, case .link = p.part {
            body.size.height = Sizing.linkImageSize(ref, maxWidth: body.width).1
        }
        layer.name = name
        layer.frame = body
        layer.cornerRadius = Fixture.bubbleRadius
        layer.masksToBounds = true
        layer.contentsGravity = .resizeAspectFill
        layer.backgroundColor = Fixture.incoming.cgColor
        if let t = MediaCache.thumb(ref) { layer.contents = t } else {
            layer.contents = nil
            MediaCache.requestThumb(ref) { [weak layer] in
                guard let layer, layer.name == name, layer.contents == nil, let t = MediaCache.thumb(ref) else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.contents = t
                CATransaction.commit()
            }
        }
        return true
    }
    /// Before a real bitmap goes on the layer.
    static func clear(_ layer: CALayer) {
        guard layer.name == name else { return }
        layer.name = nil
        layer.cornerRadius = 0
        layer.masksToBounds = false
        layer.contentsGravity = .resize
        layer.backgroundColor = nil
    }
}

/// Prefetch in the scroll direction (the recycler calls it every layout pass): row bitmaps
/// for the next 0.35 s of travel at the current velocity, thumbnails for twice as far.
/// One per transcript (RowRecycler.prefetcher), on the transcript's own clock
/// (`RowRecycler.clock`: the engine clock, virtual in harness and capture runs), so the
/// same scroll offsets always give the same velocity and the same extra cells.
final class ScrollPrefetcher {
    private var lastY = CGFloat.nan, lastT: CFTimeInterval = 0
    private(set) var velocity: CGFloat = 0
    static var requests = 0
    static let enabled = !ProcessInfo.processInfo.arguments.contains("--no-media-prefetch")
    static let precommit = !ProcessInfo.processInfo.arguments.contains("--no-precommit")
    func update(_ r: RowRecycler) {
        guard ScrollPrefetcher.enabled else { return } // cmux: no RowBitmaps.prerenderEnabled
        let y = r.bounds.minY, t = r.clock()
        if t < r.pageJumpUntil {
            // A track-click page: the jump is no velocity, and the page code prepares its rows.
            r.leadTop = 0; r.leadBottom = 0; velocity = 0; lastY = y; lastT = t
            return
        }
        if !lastY.isNaN, t - lastT > 0.001, t - lastT < 0.25 {
            velocity = 0.5 * velocity + 0.5 * (y - lastY) / CGFloat(t - lastT)
        } else if t - lastT >= 0.25 { velocity = 0 }
        lastY = y; lastT = t
        // Pre-commit: 0.1 s of travel ahead (at most a screen) gets cells now.
        let lead = ScrollPrefetcher.precommit && abs(velocity) > 300 ? min(abs(velocity) * 0.1, r.bounds.height) : 0
        r.leadTop = velocity < 0 ? lead : 0
        r.leadBottom = velocity > 0 ? lead : 0
        guard abs(velocity) > 300 else { return }
        let h = r.bounds.height
        let near = min(abs(velocity) * 0.35, 4 * h), far = min(2 * near, 8 * h)
        let rect = velocity < 0 ? CGRect(x: 0, y: r.bounds.minY - far, width: r.bounds.width, height: far)
                                : CGRect(x: 0, y: r.bounds.maxY, width: r.bounds.width, height: far)
        let n = r.layout.model.count
        let scale = r.labRenderScale // its window view's (two views can show at two scales)
        for a in r.layout.layoutAttributesForElements(in: rect) ?? [] where a.indexPath.item < n {
            guard let spec = r.layout.model.rows[checked: a.indexPath.item]?.spec, let ref = MediaPlaceholder.ref(spec) else { continue } // checked
            if MediaCache.thumb(ref) == nil { MediaCache.requestThumb(ref) }
            let dist = velocity < 0 ? r.bounds.minY - a.frame.maxY : a.frame.minY - r.bounds.maxY
            if dist < near, !RowBitmaps.shared.has(spec, scale: scale) { RowBitmaps.shared.request(spec, scale: scale); ScrollPrefetcher.requests += 1 }
        }
    }
}
