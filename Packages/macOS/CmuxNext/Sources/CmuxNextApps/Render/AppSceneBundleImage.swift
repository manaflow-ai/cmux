import AppKit
public import CmuxNextCompat
import SwiftUI

/// `Image(src)`: a file inside the app bundle (never the network).
struct AppSceneBundleImage: View {
    let path: String?
    @Environment(\.appBundleDirectory) private var directory

    var body: some View {
        if let image = AppBundleImageCache.shared.image(path: path, in: directory) {
            Image(nsImage: image).resizable().scaledToFit()
        }
    }
}

/// Decoded bundle images, keyed by absolute path, least recently used first. Paths are validated
/// to stay inside the bundle directory.
///
/// It is one lossless memory consumer once the composition root calls
/// ``registerMemoryConsumer(with:)`` (Chrome's base/memory_coordinator/memory_consumer.h): the
/// limit scales how many images it keeps, a release drops the least recently used down to that,
/// and an image drawn after a release is read again.
@MainActor
public final class AppBundleImageCache {
    /// The cache every app scene and section header reads.
    public static let shared = AppBundleImageCache()

    /// Images kept at the full memory limit.
    let maxCount: Int
    /// Images kept now: `maxCount` scaled by the memory limit (0 at critical: none kept).
    private(set) var countLimit: Int
    private var images: [String: NSImage] = [:]
    /// The keys of `images`, least recently used first (at most `maxCount`, 64: O(64) edits).
    private var order: [String] = []
    /// The decoded bytes of each image, by key, and their sum.
    private var sizes: [String: Int] = [:]
    private(set) var bytes = 0
    private var memoryRegistration: MemoryConsumerRegistration?

    init(maxCount: Int = 64) {
        self.maxCount = max(0, maxCount)
        countLimit = self.maxCount
    }

    /// Registers with the app's memory coordinator (once; a later call replaces the registration).
    ///
    /// - Parameter registry: The memory coordinator.
    public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        memoryRegistration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    func image(path: String?, in directory: URL?) -> NSImage? {
        guard let path, let directory, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let url = directory.appending(path: path).standardizedFileURL
        guard url.path.hasPrefix(directory.standardizedFileURL.path) else { return nil }
        let key = url.path
        if let cached = images[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return cached
        }
        guard let data = try? Data(blockingContentsOf: url), let image = blockingNSImage(data) else { return nil }
        insert(image, bytes: Self.decodedBytes(of: image, encoded: data.count), for: key)
        return image
    }

    /// Keeps `image` within the count limit, dropping the least recently used past it.
    private func insert(_ image: NSImage, bytes size: Int, for key: String) {
        guard countLimit > 0 else { return }
        images[key] = image
        order.append(key)
        sizes[key] = size
        bytes += size
        while order.count > countLimit { dropOldest() }
    }

    private func dropOldest() {
        guard !order.isEmpty else { return }
        let key = order.removeFirst()
        images[key] = nil
        bytes -= sizes.removeValue(forKey: key) ?? 0
    }

    /// The pixels of the largest bitmap representation at 4 bytes each; the file's bytes when it
    /// has none (a vector image).
    private static func decodedBytes(of image: NSImage, encoded: Int) -> Int {
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        return pixels > 0 ? pixels * 4 : encoded
    }
}

extension AppBundleImageCache: MemoryConsumer {
    /// Small (bundle icons and pictures), lossless (read again from the bundle), but read on the main
    /// actor to come back: warning pressure leaves it whole and critical pressure empties it.
    public static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .small,
        dataAccess: .none,
        retention: .lossless,
        recreateCost: .expensive,
        releaseCPUCost: .low,
        isStateful: true,
        supportsMemoryLimit: true
    )

    /// The consumer's name in the memory report.
    public static let memoryConsumerName = "app-bundle-images"

    /// Scales how many images it keeps from now on; frees nothing (the next read drops the oldest
    /// past the new limit).
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        countLimit = limit.scale(maxCount)
    }

    /// Drops the least recently used images down to what the slice's limit keeps, one at a time
    /// until the slice ends.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        while order.count > countLimit {
            if slice.isExpired { return .more }
            dropOldest()
        }
        return .done
    }

    /// Decoded bytes from a counter.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: bytes, entries: images.count)
    }
}
