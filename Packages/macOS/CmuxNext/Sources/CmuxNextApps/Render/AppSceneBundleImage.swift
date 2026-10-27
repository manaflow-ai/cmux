import AppKit
public import CmuxNextCompat
import SwiftUI

/// `Image(src)`: a file inside the app bundle (never the network).
struct AppSceneBundleImage: View {
    let path: String?
    @Environment(\.appBundleDirectory) private var directory
    @Environment(\.appBundleImages) private var images

    var body: some View {
        if let image = images?.image(path: path, in: directory) {
            Image(nsImage: image).resizable().scaledToFit()
        }
    }
}

extension EnvironmentValues {
    /// The decoded bundle images of the app scenes below: the apps client's one cache, which
    /// ``AppSceneView`` and the sidebar section provider set. Nil draws no bundle image.
    @Entry var appBundleImages: AppBundleImageCache?
}

/// Decoded bundle images, keyed by absolute path, least recently used first. Paths are validated
/// to stay inside the bundle directory. ``AppsClient`` holds the one instance its owner makes.
///
/// It is one lossless memory consumer once its owner calls ``registerMemoryConsumer(with:)``
/// (Chrome's base/memory_coordinator/memory_consumer.h): the limit scales how many images it keeps,
/// and a release drops the least recently used down to that. The working set stays at every limit
/// (p07-memory.md section 3.A): an image drawn less than ``workingSet`` ago is never dropped, and an
/// image a view reads now is always kept.
@MainActor
public final class AppBundleImageCache {
    /// Images drawn this recently are never dropped (as `WarmSetRelease.workingSet`, p07-memory.md 3.A).
    static let workingSet: Duration = .seconds(2)

    private struct Entry {
        let image: NSImage
        let bytes: Int
        var used: ContinuousClock.Instant
    }

    /// Images kept at the full memory limit, beyond the working set.
    let maxCount: Int
    /// Images kept now beyond the working set: `maxCount` scaled by the memory limit.
    private(set) var countLimit: Int
    private let now: @MainActor () -> ContinuousClock.Instant
    private var images: [String: Entry] = [:]
    /// The keys of `images`, least recently used first (`maxCount` plus the working set: O(64) edits).
    private var order: [String] = []
    private(set) var bytes = 0
    private var memoryRegistration: MemoryConsumerRegistration?

    /// Makes an empty cache.
    ///
    /// - Parameters:
    ///   - maxCount: Images kept at the full memory limit, beyond the working set.
    ///   - now: The clock the working set is measured on (tests pass their own).
    public init(maxCount: Int = 64, now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.maxCount = max(0, maxCount)
        countLimit = self.maxCount
        self.now = now
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
        if var cached = images[key] {
            cached.used = now()
            images[key] = cached
            order.removeAll { $0 == key }
            order.append(key)
            return cached.image
        }
        guard let data = try? Data(blockingContentsOf: url), let image = blockingNSImage(data) else { return nil }
        // Drawn now, so in the working set: kept whatever the limit; older ones past it go.
        let entry = Entry(image: image, bytes: Self.decodedBytes(of: image, encoded: data.count), used: now())
        images[key] = entry
        order.append(key)
        bytes += entry.bytes
        _ = trim { false }
        return image
    }

    /// Drops the least recently used images while more than ``countLimit`` are kept and the oldest is
    /// out of the working set, checking `isExpired` before each. False when the slice ended first.
    private func trim(until isExpired: () -> Bool) -> Bool {
        let instant = now()
        while order.count > countLimit, let oldest = order.first, let entry = images[oldest],
              instant - entry.used >= Self.workingSet {
            if isExpired() { return false }
            order.removeFirst()
            images[oldest] = nil
            bytes -= entry.bytes
        }
        return true
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
    /// actor to come back: warning pressure leaves it whole and critical pressure empties it down to
    /// its working set.
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
    /// until the slice ends; the working set stays.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        return trim(until: { slice.isExpired }) ? .done : .more
    }

    /// Decoded bytes from a counter.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: bytes, entries: images.count)
    }
}
