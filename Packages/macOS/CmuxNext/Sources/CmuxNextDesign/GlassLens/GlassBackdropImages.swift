public import AppKit
public import CmuxNextCompat
import ImageIO
import UniformTypeIdentifiers

/// The wallpaper stills pages lens (`image` of the `cmuxTheme.backdrop` payload): each art image
/// as a `data:image/jpeg` URL no wider than ``maxPixelSize``, encoded once off the main actor and
/// shared by every page that shows the same art (the decoded art is one `NSImage` per art,
/// `BackdropImageStore`). A few recent ones are kept, keyed by image identity.
///
/// Registered (``registerMemoryConsumer(with:)``), the stills are one lossless memory consumer: under a lower
/// limit the least recently asked encoded stills go first, down to the limit's share of the capacity, and a page
/// that asks again gets its still encoded again. A still still encoding is never let go (its pages wait for it).
@MainActor
public final class GlassBackdropImages {
    /// The app's stills.
    public static let shared = GlassBackdropImages()

    /// The longest side of a still, in pixels.
    public let maxPixelSize: Int
    private let capacity: Int
    /// Least recently asked first.
    private var entries: [Entry] = []
    private var serial = 0
    /// The UTF-8 bytes of the encoded stills' data URLs, kept on every encode and removal (the memory report).
    private var encodedBytes = 0
    /// How many stills stay: ``capacity`` scaled by the memory coordinator's limit, never under 1 (the one asked now).
    private var heldLimit: Int
    private var memoryRegistration: MemoryConsumerRegistration?

    private final class Entry {
        let image: NSImage
        let key: String
        var dataURL: String?
        var waiters: [@MainActor () -> Void] = []

        init(image: NSImage, key: String) {
            self.image = image
            self.key = key
        }
    }

    /// A bitmap handed to the encoding task.
    // crash-allow: an immutable CGImage is only read by the detached encoder.
    private struct Bitmap: @unchecked Sendable {
        let image: CGImage
    }

    /// - Parameters:
    ///   - maxPixelSize: The longest side of a still.
    ///   - capacity: How many stills stay encoded.
    public init(maxPixelSize: Int = 1024, capacity: Int = 4) {
        self.maxPixelSize = max(maxPixelSize, 16)
        self.capacity = max(capacity, 1)
        heldLimit = self.capacity
    }

    /// The key and, once encoded, the data URL of `image` (empty when it could not be encoded).
    /// While it encodes the URL is nil and `ready` runs on the main actor when it is done; nil
    /// when the image has no bitmap.
    public func still(_ image: NSImage, ready: @escaping @MainActor () -> Void) -> (key: String, dataURL: String?)? {
        if let index = entries.firstIndex(where: { $0.image === image }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            if entry.dataURL == nil { entry.waiters.append(ready) }
            return (entry.key, entry.dataURL)
        }
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        serial += 1
        let entry = Entry(image: image, key: "still-\(serial)")
        entry.waiters = [ready]
        entries.append(entry)
        dropEncoded(downTo: heldLimit)
        let source = Bitmap(image: bitmap), size = maxPixelSize
        // main-hop-allow: the task only awaits its detached encode; its one resume stores the URL and marks each waiting feed for its next update
        Task { [weak self, weak entry] in
            let url = await Task.detached(priority: Task.currentPriority) { Self.jpegDataURL(source.image, maxPixelSize: size) }.value
            guard let entry else { return }
            entry.dataURL = url ?? ""
            self?.encodedBytes += entry.dataURL?.utf8.count ?? 0
            let waiters = entry.waiters
            entry.waiters = []
            waiters.forEach { $0() }
        }
        return (entry.key, nil)
    }

    /// Drops the least recently asked encoded stills until at most `keep` stills stay. A still encoding stays
    /// (its pages wait for its `ready`), so the stills go over `keep` until those encodes end and the next new
    /// still or release trims them.
    ///
    /// - Parameters:
    ///   - keep: How many stills may stay.
    ///   - slice: The release's time slice; nil when a new still trims.
    /// - Returns: `.more` when `slice` expired before the stills got down to `keep`.
    @discardableResult
    private func dropEncoded(downTo keep: Int, within slice: MemoryReleaseSlice? = nil) -> MemoryReleaseProgress {
        while entries.count > keep, let index = entries.firstIndex(where: { $0.dataURL != nil }) {
            if slice?.isExpired == true { return .more }
            let entry = entries.remove(at: index)
            encodedBytes -= entry.dataURL?.utf8.count ?? 0
        }
        return .done
    }

    /// `image` scaled down to at most `maxPixelSize` on its longest side and encoded as a JPEG
    /// data URL; nil when it cannot be drawn or encoded. Runs off the main actor.
    nonisolated static func jpegDataURL(_ image: CGImage, maxPixelSize: Int) -> String? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let scale = min(1, Double(maxPixelSize) / Double(longest))
        let width = max(Int((Double(image.width) * scale).rounded()), 1)
        let height = max(Int((Double(image.height) * scale).rounded()), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }
}

/// The encoded stills as one lossless consumer (Chrome's consumer contract, base/memory_coordinator/memory_consumer.h):
/// a new limit only lowers how many stills ``still(_:ready:)`` keeps; ``releaseMemory(within:)`` drops down to it.
extension GlassBackdropImages: MemoryConsumer {
    /// A few JPEG data URLs of at most 1024 pixels (well under 1 MB in all); dropping one touches only memory and
    /// encoding it again is one off-main JPEG encode of a decoded image.
    public nonisolated static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .small, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)

    /// The consumer's name in the memory report.
    public nonisolated static let memoryConsumerName = "glass-backdrop-stills"

    /// Makes the stills a consumer of `registry`; a later call replaces the registration.
    ///
    /// - Parameter registry: The memory coordinator, from the composition root.
    public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        memoryRegistration?.cancel()
        memoryRegistration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    /// Lowers how many stills the next ask keeps. Frees nothing.
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        heldLimit = max(limit.scale(capacity), 1)
    }

    /// Drops the least recently asked encoded stills down to the limit's share of the capacity; stills still
    /// encoding stay.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        return dropEncoded(downTo: slice.limit.scale(capacity), within: slice)
    }

    /// The encoded stills' bytes and how many stills it holds, from two counters.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: encodedBytes, entries: entries.count)
    }
}
