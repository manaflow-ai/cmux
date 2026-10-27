import AppKit
public import CmuxNextCompat
import CmuxNextIcons
public import CmuxNextWakeups
import SwiftUI

/// `Image(src)`: a file inside the app bundle (never the network). An image not decoded yet draws
/// nothing until it is read and decoded off the main thread (``AppBundleImageCache/load(path:in:)``).
struct AppSceneBundleImage: View {
    let path: String?
    @Environment(\.appBundleDirectory) private var directory

    var body: some View {
        // The placeholder takes no room, as no image did before; it is a view (not EmptyView) so its load task runs.
        AppBundleImageView(path: path, directory: directory) { Image(nsImage: $0).resizable().scaledToFit() } placeholder: {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

/// A bundle image from the environment's ``AppBundleImageCache``: `content` with the kept image, else `placeholder`
/// while the file is read and decoded off the main thread (or when it does not decode).
struct AppBundleImageView<Content: View, Placeholder: View>: View {
    let path: String?
    let directory: URL?
    @ViewBuilder let content: (NSImage) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @Environment(\.appBundleImages) private var images
    /// The image this view loaded (it is in the cache too, until a memory release drops it).
    @State private var loaded: (key: AppBundleImageCache.LoadKey, image: NSImage)?

    var body: some View {
        let key = AppBundleImageCache.LoadKey(path: path, directory: directory)
        if let image = images?.cachedImage(path: path, in: directory) ?? (loaded?.key == key ? loaded?.image : nil) {
            content(image)
        } else {
            placeholder().task(id: key) {
                guard let images, let image = await images.load(path: path, in: directory) else { return }
                loaded = (key, image)
            }
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
    /// Reads and decodes the files off the main thread.
    private let work: BackgroundWork

    /// What one bundle image view loads: its path in its bundle.
    nonisolated struct LoadKey: Hashable, Sendable {
        let path: String?
        let directory: URL?
    }

    /// Makes an empty cache.
    ///
    /// - Parameters:
    ///   - work: The app's lanes: the files are read and decoded on its `.files` lane.
    ///   - maxCount: Images kept at the full memory limit, beyond the working set.
    ///   - now: The clock the working set is measured on (tests pass their own).
    public init(work: BackgroundWork, maxCount: Int = 64,
                now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.work = work
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

    /// The absolute path of `path` in `directory`, nil when it would leave the bundle.
    private static func file(_ path: String?, in directory: URL?) -> URL? {
        guard let path, let directory, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let url = directory.appending(path: path).standardizedFileURL
        return url.path.hasPrefix(directory.standardizedFileURL.path) ? url : nil
    }

    /// The decoded image of `path` in `directory` when it is kept, marked as drawn now; nil when it is not decoded yet.
    func cachedImage(path: String?, in directory: URL?) -> NSImage? {
        guard let key = Self.file(path, in: directory)?.path, var cached = images[key] else { return nil }
        cached.used = now()
        images[key] = cached
        order.removeAll { $0 == key }
        order.append(key)
        return cached.image
    }

    /// The image of `path` in `directory`: the kept one, else the file read and decoded on the `.files` lane, then
    /// kept. Nil when the path leaves the bundle, or the file does not read or decode.
    func load(path: String?, in directory: URL?) async -> NSImage? {
        if let cached = cachedImage(path: path, in: directory) { return cached }
        guard let url = Self.file(path, in: directory),
              let read = try? await work.run(.userVisible, mayBlock: .files, { Self.read(url) }) else { return nil }
        // Another view's load of the same file may have landed first.
        if let cached = cachedImage(path: path, in: directory) { return cached }
        let image: NSImage
        switch read.contents {
        case .bitmap(let bitmap):
            image = NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
        case .vector(let data):
            // decode: an SVG or a PDF, which only NSImage reads: it parses here, in blockingNSImage's checked call,
            // and draws as vectors; a bitmap never comes this way.
            guard let vector = blockingNSImage(data) else { return nil }
            image = vector
        }
        // Drawn now, so in the working set: kept whatever the limit; older ones past it go.
        let entry = Entry(image: image, bytes: Self.decodedBytes(of: image, encoded: read.encodedBytes), used: now())
        images[url.path] = entry
        order.append(url.path)
        bytes += entry.bytes
        _ = trim { false }
        return image
    }

    /// A file's image as the lane hands it back: a bitmap decoded to pixels, or a vector file's data.
    private nonisolated struct Read: Sendable {
        nonisolated enum Contents: Sendable {
            case bitmap(CGImage)
            case vector(Data)
        }

        let contents: Contents
        let encodedBytes: Int
    }

    /// Reads `url` and decodes a bitmap at its full size (``IconAssetDecode``); an SVG or a PDF comes back as data.
    /// Runs on a lane thread.
    private nonisolated static func read(_ url: URL) -> Read? {
        guard let data = try? Data(blockingContentsOf: url) else { return nil }
        if let bitmap = IconAssetDecode.thumbnail(data, types: IconAssetDecode.bitmapTypes, maxPixelSize: IconAssetDecode.maxSide) {
            return Read(contents: .bitmap(bitmap), encodedBytes: data.count)
        }
        let isPDF = data.starts(with: Array("%PDF".utf8))
        return IconAssetDecode.isSVGText(data) || isPDF ? Read(contents: .vector(data), encodedBytes: data.count) : nil
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
