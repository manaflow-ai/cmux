import CmuxNextCompat
import CmuxNextMemory
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Hibernated pages' last frames, kept compressed (JPEG, or PNG when transparent) under their
/// own budget, least recently used first out, so every hibernated tab wakes to its picture
/// (PR 23083). They used to share the decoded `previews` LRU with terminal previews at up
/// to a quarter of it each: four hibernated pages kept a picture and the others woke to an empty
/// pane. With feature `compressedSnapshots` off it keeps decoded pictures instead, under
/// the same budget and the same neighbor rule.
///
/// Its full size is `ImageCacheShares.hibernationSnapshotBytes`: with `memoryImageCaches` on,
/// `SubsystemBudget.hibernationSnapshotBytes` (M / 256 MiB: 64 MiB on a 16 GB Mac,
/// plans/cmux-next/chrome-parity/p07-memory.md, task 058), else 64 MB. Registered with the memory coordinator
/// (`memoryImageCaches`), it is a lossy consumer (a dropped picture comes back only at the page's next
/// sleep, and its wake shows the page loading) that the coordinator limits only at critical pressure,
/// in the last release tier. Under a limit it keeps the N most recent pictures that fit the scaled
/// bytes, and always the pictures of the tabs beside each shown tab (``neighbors``), which Ctrl-Tab and
/// Cmd-Shift-[ ] wake next: at the critical limit (0 %) only those stay. Chrome keeps no picture of a
/// discarded tab; its `FrameEvictionManager` (components/viz/client/frame_eviction_manager.cc) keeps
/// the saved frames of the most recently shown hidden views and culls them on `OnReleaseMemory`.
///
/// A picture's image decodes from its bytes when drawn; the placeholder decodes it off the main
/// thread, and holds the decoded pixels only while a pane shows it (`HibernatedBrowserTab`).
@MainActor
final class HibernationSnapshots {
    /// The consumer's name in the memory report.
    static let memoryConsumerName = "hibernation-snapshots"
    /// The consumer's traits: lossy and expensive to rebuild (only a new sleep pictures the page again),
    /// so the coordinator leaves it whole at warning and releases it in its last tier; it honors partial limits.
    static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large,
        dataAccess: .none,
        retention: .lossy,
        recreateCost: .expensive,
        releaseCPUCost: .low,
        isStateful: true,
        supportsMemoryLimit: true
    )

    /// The bytes it keeps at the default limit. A page picture at 2x is about 0.2 to 1.5 MB as JPEG,
    /// so 64 MiB holds 40 to 300 of them.
    let fullCapacityBytes: Int
    /// The bytes it keeps now: ``fullCapacityBytes`` scaled by the memory coordinator's limit. The
    /// neighbors' pictures stay past it.
    var capacityBytes: Int { memoryLimit.scale(fullCapacityBytes) }
    /// The limit the memory coordinator gave last.
    private(set) var memoryLimit = MemoryLimit.default
    /// The tabs beside each shown tab now, whose pictures are kept at any limit (`BrowserHibernation`
    /// sets it; read once per trim).
    var neighbors: () -> Set<String> = { [] }
    /// Whether a new picture is kept compressed: feature `compressedSnapshots` (on by default; the App sets it
    /// from this launch's features).
    var keepsCompressed = true
    private(set) var totalBytes = 0
    private var pictures: [String: Picture] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var memoryRegistration: MemoryConsumerRegistration?

    /// One page's picture: `data` is the JPEG or PNG (nil for a decoded picture, when
    /// feature `compressedSnapshots` is off), `image` decodes from it.
    nonisolated struct Picture: Sendable {
        let data: Data?
        let image: CGImage

        /// The bytes it holds in the store: the compressed bytes, or the decoded pixels.
        var cost: Int { data?.count ?? max(image.bytesPerRow * image.height, image.width * image.height * 4) }
    }

    /// - Parameter fullCapacityBytes: The bytes it keeps at the default limit (`ImageCacheShares.hibernationSnapshotBytes`).
    init(fullCapacityBytes: Int) {
        self.fullCapacityBytes = max(0, fullCapacityBytes)
    }

    var count: Int { pictures.count }

    /// Registers with the app's memory coordinator (once; a later call replaces the registration).
    ///
    /// - Parameter registry: The memory coordinator.
    func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        memoryRegistration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    func image(for key: String) -> CGImage? {
        guard let picture = pictures[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return picture.image
    }

    /// Whether a new picture of `key` would be kept now: the limit leaves room, or `key` is a neighbor's.
    /// A hibernation asks before it captures, so the critical limit pays for no picture it drops.
    func keeps(_ key: String) -> Bool {
        capacityBytes > 0 || neighbors().contains(key)
    }

    /// Keeps `picture` for `key` as the most recent one, then drops the oldest pictures that are not a
    /// neighbor's only as far as the store would grow past ``capacityBytes`` or its size before the insert,
    /// whichever is larger: the drop down to a lowered limit is the release slices' work. A picture larger
    /// than the full store is not kept.
    func insert(_ picture: Picture, for key: String) {
        let cost = picture.cost
        guard cost <= fullCapacityBytes else { return }
        let ceiling = max(capacityBytes, totalBytes)
        remove(key)
        pictures[key] = picture
        order.append(key)
        totalBytes += cost
        _ = trim(to: ceiling, within: nil)
    }

    func remove(_ key: String) {
        guard let picture = pictures.removeValue(forKey: key) else { return }
        totalBytes -= picture.cost
        order.removeAll { $0 == key }
    }

    /// Drops the oldest pictures that are not a neighbor's until the store holds at most `capacity`
    /// bytes or `slice` expires: one pass over the order, O(pictures).
    private func trim(to capacity: Int, within slice: MemoryReleaseSlice?) -> MemoryReleaseProgress {
        guard totalBytes > capacity else { return .done }
        let kept = neighbors()
        var survivors: [String] = []
        var index = 0
        var progress = MemoryReleaseProgress.done
        while totalBytes > capacity, index < order.count {
            if slice?.isExpired == true {
                progress = .more
                break
            }
            let key = order[index]
            index += 1
            if kept.contains(key) {
                survivors.append(key)
            } else if let picture = pictures.removeValue(forKey: key) {
                totalBytes -= picture.cost
            }
        }
        order = survivors + order[index...]
        return progress
    }

    /// Pixels a picture keeps at most: a 2560 x 1600 pt pane at 2x (16.4 M) keeps its size.
    nonisolated static let maxPixels = 16 << 20

    /// `image` as a JPEG at most `maxPixels` large (same aspect and color space), encoded on a
    /// background task; a PNG when it has transparent pixels, which JPEG would turn black (a page
    /// with a transparent background); nil when ImageIO cannot encode it.
    nonisolated static func compress(_ image: CGImage, quality: Double = 0.8) async -> Picture? {
        await Task.detached(priority: .userInitiated) { compressed(image, quality: quality) }.value
    }

    nonisolated static func compressed(_ image: CGImage, quality: Double) -> Picture? {
        let pixels = Double(image.width * image.height)
        let scale = min(1, (Double(maxPixels) / max(pixels, 1)).squareRoot())
        let source = scale < 1
            ? TabPreviewFitting.fitted(image, CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale))
            : image
        let data = NSMutableData()
        let type = isOpaque(source) ? UTType.jpeg : UTType.png
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let bytes = data as Data
        guard let decoded = CheckedImageSource(bytes)?.image(at: 0, options: [kCGImageSourceShouldCache: false]) else { return nil }
        return Picture(data: bytes, image: decoded)
    }

    /// True when `image` has no alpha, or no transparent pixel in a 32 x 32 sample of it (a
    /// transparent background spans most of a page; an engine's opaque picture often has alpha).
    nonisolated static func isOpaque(_ image: CGImage) -> Bool {
        if [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) { return true }
        let side = 32
        guard let context = CGContext.bitmapOwningPixels(width: side, height: side, bytesPerRow: side * 4,
                                                         space: CGColorSpaceCreateDeviceRGB(),
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        // The sample's bytes are read back as a copy (rows of exactly side * 4 bytes), not through the context's buffer.
        guard let pixels = context.makeImage()?.dataProvider?.data as Data?, pixels.count >= side * side * 4 else { return false }
        return stride(from: 3, to: side * side * 4, by: 4).allSatisfy { pixels[pixels.startIndex + $0] == 255 }
    }
}

extension HibernationSnapshots: MemoryConsumer {
    /// Keeps the limit: the next picture kept trims to it. Frees nothing.
    func updateMemoryLimit(_ limit: MemoryLimit) {
        memoryLimit = limit
    }

    /// Drops the oldest pictures that are not a neighbor's until the store fits the slice's limit.
    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        trim(to: slice.limit.scale(fullCapacityBytes), within: slice)
    }

    /// The compressed bytes and picture count, from counters.
    var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: totalBytes, entries: pictures.count)
    }
}
