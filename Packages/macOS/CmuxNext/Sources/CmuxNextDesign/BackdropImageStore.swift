public import AppKit
import AVFoundation
public import CmuxNextCompat
import CoreImage
import ImageIO
import UniformTypeIdentifiers
public import CmuxNextDesignTokens
public import CmuxNextAppearance

/// Backdrop images decoded, textured and cached once per process, shared by every window, and
/// kept on disk for the next launch.
///
/// The decode, the downscale to the largest screen and the texture pass all run off the main
/// actor (a 2400 px painting cost the first frame about 50 ms when AppKit decoded it in the
/// commit, and the texture pass encoded it as TIFF on the main actor). The result is written to
/// ``snapshots``, so the next launch's first window shows the art at once: ``preview(_:texture:)``
/// decodes a small copy of the snapshot for that frame, and ``prewarm(_:texture:)`` starts the
/// full load when settings pick the art, before any window asks.
///
/// Registered (``registerMemoryConsumer(with:)``), the store is one lossless memory consumer: it holds
/// at most the limit's share of ``fullCount`` decoded images and lets the least recently used go first,
/// as Chrome's image decode caches do (cc/tiles/software_image_decode_cache.cc on
/// base/containers/lru_cache.h). An image let go stays found while a window shows it (Chrome never
/// purges a decode in use), so a second window does not decode a second copy; one no window shows is
/// freed. Unregistered, the store holds every image it decoded.
@MainActor
public final class BackdropImageStore {
    /// The app's store, with snapshots in the app's caches folder.
    public static let shared = BackdropImageStore(snapshots: defaultSnapshots)

    /// The longest side, in pixels, of a decoded backdrop: by default the largest screen's.
    public let maxPixelSize: Int
    /// Where snapshots of the decoded, textured images live; nil keeps none.
    public let snapshots: URL?
    /// Texture passes run (tests).
    private(set) var renderCount = 0

    /// Fetches the full image of art that does not ship in the app.
    private let downloads: BackdropArtDownloads
    /// The decoded images the store holds.
    private var images: [Key: Decode] = [:]
    /// The keys of ``images``, least recently used first.
    private var order: [Key] = []
    /// Images the store let go of, found again while a window still shows one.
    private var shown: [Key: ShownDecode] = [:]
    /// The bitmap bytes of ``images``.
    private var heldBytes = 0
    /// How many decoded images the store holds; nil (unregistered) holds every one.
    private var holdLimit: Int?
    private var memoryRegistration: MemoryConsumerRegistration?
    private var loads: [Key: Task<Decoded?, Never>] = [:]
    private var warming: [Task<Void, Never>] = []

    private struct Key: Hashable {
        let id: String
        let texture: BackdropTexture
    }

    /// One decoded image the store holds, with its bitmap's bytes.
    private struct Decode {
        let image: NSImage
        let bytes: Int
    }

    /// A decoded image the store let go of: alive while a window holds it.
    private struct ShownDecode {
        weak var image: NSImage?
        let bytes: Int
    }

    /// A decoded bitmap handed from the decoding task to the main actor.
    // crash-allow: immutable CGImage is transferred from the detached decoder to the main actor.
    private struct Decoded: @unchecked Sendable {
        let image: CGImage
        /// Whether a texture pass ran (not read back from a snapshot).
        let rendered: Bool
    }

    /// The longest side of a snapshot preview: enough under the window's tint for the frames
    /// before the full image arrives, and quick to decode on the main actor.
    nonisolated static let previewPixelSize = 640

    /// The app's snapshot folder in its caches.
    public nonisolated static var defaultSnapshots: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux-next", isDirectory: true)
            .appendingPathComponent("Backdrops", isDirectory: true)
    }

    /// - Parameters:
    ///   - maxPixelSize: The longest side of a decoded backdrop; nil for the largest screen's.
    ///   - snapshots: Where to keep snapshots for the next launch; nil keeps none.
    ///   - downloads: Where art that does not ship in the app comes from.
    public init(maxPixelSize: Int? = nil, snapshots: URL? = nil, downloads: BackdropArtDownloads = .shared) {
        self.maxPixelSize = max(maxPixelSize ?? Self.screenPixelSize(), 64)
        self.snapshots = snapshots
        self.downloads = downloads
    }

    /// The longest side of the largest screen, in pixels.
    static func screenPixelSize() -> Int {
        let sizes = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
        return Int((sizes.max() ?? 2560).rounded(.up))
    }

    /// The decoded image of `selection` (in light or `dark`, for one that follows the
    /// appearance), or nil until it has loaded.
    func cached(_ selection: BackdropSelection, texture: BackdropTexture = .default, dark: Bool = false) -> NSImage? {
        held(Key(id: selection.variantID(dark: dark), texture: texture))
    }

    /// A small copy of an earlier launch's snapshot of `selection`, decoded now, for the frames
    /// before ``image(_:texture:)`` finishes; without one, the art's bundled thumbnail (art that
    /// still has to download shows it at once). Nil when there is neither.
    func preview(_ selection: BackdropSelection, texture: BackdropTexture = .default, dark: Bool = false) -> NSImage? {
        let size = min(Self.previewPixelSize, maxPixelSize)
        let image = snapshotURL(selection, texture: texture, dark: dark).flatMap { Self.decode($0, maxPixelSize: size) }
            ?? Self.thumbnail(of: selection).flatMap { Self.decode($0, maxPixelSize: size) }
        return image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    private static func thumbnail(of selection: BackdropSelection) -> URL? {
        guard case .art = selection else { return nil }
        return selection.thumbnailURL
    }

    /// Starts loading `selection` so the first window that shows it finds it decoded.
    public func prewarm(_ selection: BackdropSelection?, texture: BackdropTexture = .default) {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let selection, cached(selection, texture: texture, dark: dark) == nil else { return }
        // task-owner: one load per prewarm, kept in `warming` so tests can wait for it
        // main-hop-allow: image(_:texture:dark:) is the store's main-actor cache, whose decode and texture run detached
        // off main; this task only starts it, and its one resume holds the image
        warming.append(Task { [weak self] in _ = await self?.image(selection, texture: texture, dark: dark) })
    }

    /// Waits for the loads ``prewarm(_:texture:)`` started (tests).
    func settled() async {
        let running = warming
        warming = []
        for task in running { await task.value }
    }

    /// The decoded, textured image of `selection`, loading it off the main actor once.
    func image(_ selection: BackdropSelection, texture: BackdropTexture = .default, dark: Bool = false) async -> NSImage? {
        let key = Key(id: selection.variantID(dark: dark), texture: texture)
        if let image = held(key) { return image }
        if case .art(let art) = selection, art.imageURL == nil {
            // Not bundled and not downloaded yet: fetch it once, then decode as usual.
            guard await downloads.file(for: art) != nil else { return nil }
            if let image = held(key) { return image }
        }
        let load: Task<Decoded?, Never>
        if let running = loads[key] {
            load = running
        } else {
            let source = selection.resolvedImageURL(dark: dark), snapshot = snapshotURL(selection, texture: texture, dark: dark)
            let size = maxPixelSize
            load = Task.detached(priority: .userInitiated) {
                Self.load(source, snapshot: snapshot, maxPixelSize: size, texture: texture, dark: dark)
            }
            loads[key] = load
        }
        let decoded = await load.value
        loads[key] = nil
        if let image = held(key) { return image }
        guard let decoded else { return nil }
        if decoded.rendered { renderCount += 1 }
        let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
        hold(Decode(image: image, bytes: decoded.image.bytesPerRow * decoded.image.height), for: key)
        return image
    }

    /// The image of `key` the store holds, or one it let go of that a window still shows (held again,
    /// as the most recently used, when the limit allows); nil when neither.
    private func held(_ key: Key) -> NSImage? {
        if let decode = images[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return decode.image
        }
        guard let released = shown.removeValue(forKey: key), let image = released.image else { return nil }
        hold(Decode(image: image, bytes: released.bytes), for: key)
        return image
    }

    /// Holds `decode` as the most recently used image, then lets go of the least recently used ones over
    /// the limit.
    private func hold(_ decode: Decode, for key: Key) {
        if let earlier = images[key] {
            heldBytes -= earlier.bytes
            order.removeAll { $0 == key }
        }
        order.append(key)
        images[key] = decode
        heldBytes += decode.bytes
        shown = shown.filter { $0.value.image != nil }
        while let holdLimit, images.count > holdLimit, let oldest = order.first {
            letGo(oldest)
        }
    }

    /// Stops holding the image of `key`; it stays found while a window shows it.
    private func letGo(_ key: Key) {
        order.removeAll { $0 == key }
        guard let decode = images.removeValue(forKey: key) else { return }
        heldBytes -= decode.bytes
        shown[key] = ShownDecode(image: decode.image, bytes: decode.bytes)
    }

    /// The snapshot file of `selection` at this store's size and `texture`. Its name carries the
    /// source file's size and modification date, so a replaced file never matches an old one.
    private func snapshotURL(_ selection: BackdropSelection, texture: BackdropTexture, dark: Bool = false) -> URL? {
        guard let snapshots, let source = selection.resolvedImageURL(dark: dark),
              let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let identity = "\(selection.variantID(dark: dark))|\(texture.id)|\(maxPixelSize)|\(bytes)|\(modified)"
        return snapshots.appendingPathComponent(Self.digest(identity) + ".jpg")
    }

    /// The snapshot when there is one, else the source decoded, textured and snapshotted.
    private nonisolated static func load(_ source: URL?, snapshot: URL?, maxPixelSize: Int,
                                         texture: BackdropTexture, dark: Bool) -> Decoded? {
        if let snapshot, let image = decode(snapshot, maxPixelSize: maxPixelSize) {
            return Decoded(image: image, rendered: false)
        }
        guard let source, let image = decode(source, maxPixelSize: maxPixelSize, dark: dark) else { return nil }
        let textured = BackdropTextureRenderer(context: CIContext(options: [.cacheIntermediates: false]))
            .render(image, texture: texture)
        let result = textured ?? image
        if let snapshot { write(result, to: snapshot) }
        return Decoded(image: result, rendered: textured != nil)
    }

    /// The file decoded now (not when it first draws), its longest side at most `maxPixelSize`;
    /// a video's first frame, and a dynamic HEIC's frame for light or `dark` (``BackdropAppearance``).
    nonisolated static func decode(_ url: URL, maxPixelSize: Int, dark: Bool = false) -> CGImage? {
        if AppleWallpapers.isVideo(url.path) { return poster(url, maxPixelSize: maxPixelSize) }
        guard let source = CheckedImageSource(blockingContentsOf: url) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let frame = (dark ? BackdropAppearance.dark : .light).frame(in: source.source)
        return source.thumbnail(at: frame, options: options)
    }

    /// A video's first frame, upright, its longest side at most `maxPixelSize`: the poster a
    /// paused video wallpaper shows, and its picker thumbnail.
    public nonisolated static func poster(_ url: URL, maxPixelSize: Int) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }

    /// Writes `image` as a JPEG at `file`, through a temporary file so a reader never sees half.
    private nonisolated static func write(_ image: CGImage, to file: URL) {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(UUID().uuidString + ".partial")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: partial)
            return
        }
        if (try? FileManager.default.replaceItemAt(file, withItemAt: partial)) == nil {
            try? FileManager.default.removeItem(at: partial)
        }
    }

    /// A stable 64-bit FNV-1a digest of `text`, as hex.
    private nonisolated static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

extension BackdropImageStore: MemoryConsumer {
    /// Up to ``fullCount`` bitmaps of the largest screen's size (59 MB each on a 5K screen); letting one go
    /// touches only memory, and decoding it again reads its snapshot off the main actor.
    public nonisolated static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)

    /// The store's name in the memory report.
    public nonisolated static let memoryConsumerName = "backdrop-images"

    /// The decoded images held at the full limit: the current art in light and dark, and the art picked
    /// before it, so picking it again shows at once.
    nonisolated static let fullCount = 4

    /// Makes the store a consumer of `registry`; a later call replaces the registration.
    ///
    /// - Parameter registry: The memory coordinator, from the composition root.
    public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        memoryRegistration?.cancel()
        memoryRegistration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    public func updateMemoryLimit(_ limit: MemoryLimit) {
        holdLimit = limit.scale(Self.fullCount)
    }

    /// Lets go of one image per turn: each is a screen-sized bitmap, the turn's one costly free.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        shown = shown.filter { $0.value.image != nil }
        let limit = slice.limit.scale(Self.fullCount)
        guard images.count > limit, let oldest = order.first else { return .done }
        if slice.isExpired { return .more }
        letGo(oldest)
        return images.count > limit ? .yield : .done
    }

    /// The bitmap bytes and count of the images the store holds, not of those only a window still holds.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: heldBytes, entries: images.count)
    }
}
