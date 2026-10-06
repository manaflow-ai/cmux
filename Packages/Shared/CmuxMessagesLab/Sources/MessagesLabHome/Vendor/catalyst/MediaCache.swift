#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import ImageIO

/// Decoded images for row drawing (Images.load), bounded by bytes, and image sizes from
/// metadata (no decode). shared/LONG-MESSAGES.md, media-heavy conversations.
/// - A source wider or taller than `maxPixels` is decoded downsampled with ImageIO
///   (never full resolution in memory). Smaller sources take the previous path
///   unchanged (same pixels).
/// - Thread safe: the row bitmap queue decodes; the main thread asks `isCached`
///   before it draws a row itself (a row whose image is not decoded waits for its
///   off-main bitmap, at its final size from metadata, so no height changes).
final class MediaCache: @unchecked Sendable {
    static let shared = MediaCache()
    /// Rows draw media at most 500 pt wide at 3x (map snapshots); photos at most 300 pt.
    static let maxPixels = 2048
    var budget: Int = {
        let a = ProcessInfo.processInfo.arguments
        return (a.firstIndex(of: "--image-cache-mb").flatMap { $0 + 1 < a.count ? Int(a[$0 + 1]) : nil } ?? 96) << 20
    }()
    private let lock = NSLock()
    private var map: [String: (UIImage, Int, Int)] = [:]
    private var sizes: [String: CGSize] = [:]
    private var tick = 0
    private(set) var bytes = 0
    // Stats (bench).
    private(set) var decodes = 0, downsampled = 0, inFlight = 0, maxInFlight = 0, evicted = 0
    private(set) var decodeMsTotal = 0.0, decodeMsMax = 0.0

    func cached(_ key: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let e = map[key] else { return nil }
        tick += 1
        map[key] = (e.0, e.1, tick)
        return e.0
    }
    func isCached(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return map[key] != nil }

    func store(_ key: String, _ img: UIImage) {
        let b = img.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        lock.lock()
        if let old = map[key] { bytes -= old.1 }
        tick += 1
        map[key] = (img, b, tick)
        bytes += b
        var freed: [UIImage] = []
        if bytes > budget {
            for (k, e) in map.sorted(by: { $0.value.2 < $1.value.2 }) {
                if bytes <= budget * 4 / 5 { break }
                map[k] = nil; bytes -= e.1; freed.append(e.0); evicted += 1
            }
        }
        lock.unlock()
        if !freed.isEmpty { Reclaimer.release(freed) }
    }

    /// Pixel size from the file's metadata (no decode), cached.
    func pixelSize(_ url: URL) -> CGSize? {
        let k = url.absoluteString
        lock.lock()
        if let s = sizes[k] { lock.unlock(); return s }
        lock.unlock()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let orient = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let s = orient >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        lock.lock(); sizes[k] = s; lock.unlock()
        return s
    }

    /// Decode a raster asset at `assetScale` points per pixel: downsampled above `maxPixels`.
    func decode(_ url: URL, scale: CGFloat) -> UIImage? {
        let t0 = CACurrentMediaTime()
        lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock()
        defer {
            let ms = (CACurrentMediaTime() - t0) * 1000
            lock.lock(); inFlight -= 1; decodes += 1; decodeMsTotal += ms; decodeMsMax = max(decodeMsMax, ms); lock.unlock()
        }
        if let px = pixelSize(url), max(px.width, px.height) > CGFloat(MediaCache.maxPixels),
           let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceShouldCacheImmediately: true,
               kCGImageSourceThumbnailMaxPixelSize: MediaCache.maxPixels] as CFDictionary) {
            lock.lock(); downsampled += 1; lock.unlock()
            // The point size keeps the aspect; callers size rows from `pixelSize`, not from this image.
            return UIImage(cgImage: cg, scale: scale, orientation: .up)
        }
        guard let data = try? Data(contentsOf: url), let raw = UIImage(data: data), let cg = raw.cgImage else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up).preparingForDisplay() ?? UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return map.count }
    var stats: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["imageCacheMB": Double(bytes / 10_486) / 100, "imageCacheBudgetMB": budget >> 20, "imagesCached": map.count,
                "decodes": decodes, "downsampled": downsampled, "decodeMsMean": decodes > 0 ? (decodeMsTotal / Double(decodes) * 10).rounded() / 10 : 0,
                "decodeMsMax": (decodeMsMax * 10).rounded() / 10, "maxDecodesInFlight": maxInFlight, "evicted": evicted]
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
            if case let .threadPreview(pv) = spec.kind, let ref = previewRef(pv.part) { return isCached(ref) }
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
    private static let siblingLock = NSLock()
    private static var siblings: [String: Bool] = [:]
    /// Whether `name.png` has a `name.svg` beside it (cached file check, no parse).
    static func hasSibling(_ ref: String) -> Bool {
        guard !ref.hasPrefix("file:"), ref.hasSuffix(".png") else { return false }
        siblingLock.lock()
        if let v = siblings[ref] { siblingLock.unlock(); return v }
        siblingLock.unlock()
        let v = FileManager.default.fileExists(atPath: Fixtures.assetURL(String(ref.dropLast(4)) + ".svg").path)
        siblingLock.lock(); siblings[ref] = v; siblingLock.unlock()
        return v
    }
}
