public import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
public import CmuxNextDesignTokens

/// Backdrop images decoded, textured and cached once per process, shared by every window, and
/// kept on disk for the next launch.
///
/// The decode, the downscale to the largest screen and the texture pass all run off the main
/// actor (a 2400 px painting cost the first frame about 50 ms when AppKit decoded it in the
/// commit, and the texture pass encoded it as TIFF on the main actor). The result is written to
/// ``snapshots``, so the next launch's first window shows the art at once: ``preview(_:texture:)``
/// decodes a small copy of the snapshot for that frame, and ``prewarm(_:texture:)`` starts the
/// full load when settings pick the art, before any window asks.
@MainActor
public final class BackdropImageStore {
    /// The app's store, with snapshots in the app's caches folder.
    public static let shared = BackdropImageStore(snapshots: defaultSnapshots, desktop: .live())

    /// The longest side, in pixels, of a decoded backdrop: by default the largest screen's.
    public let maxPixelSize: Int
    /// Where snapshots of the decoded, textured images live; nil keeps none.
    public let snapshots: URL?
    /// The desktop picture: the Desktop Wallpaper art reloads when it changes, and its color leans
    /// the glass tint (``WallpaperTint``). Inert until started.
    public let desktop: DesktopWallpaperWatch
    /// Texture passes run (tests).
    private(set) var renderCount = 0

    /// Fetches the full image of art that does not ship in the app.
    private let downloads: BackdropArtDownloads
    private var images: [Key: NSImage] = [:]
    private var loads: [Key: Task<Decoded?, Never>] = [:]
    private var warming: [Task<Void, Never>] = []
    /// The desktop's ``DesktopWallpaperWatch/generation`` the cached Desktop Wallpaper shows.
    private var desktopGeneration = 0
    /// Ends when every Desktop Wallpaper decode the desktop moved on from has ended. A decode
    /// can't be stopped once it runs, so a new one waits for this: one desktop decode at a time,
    /// however fast the desktop changes and however many windows ask.
    private var retiredDesktopLoads: Task<Void, Never>?

    private struct Key: Hashable {
        let id: String
        let texture: BackdropTexture
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
    ///   - desktop: The desktop picture the Desktop Wallpaper art and the tint follow; by default
    ///     one that keeps no color between launches and stays inert until started.
    public init(maxPixelSize: Int? = nil, snapshots: URL? = nil, downloads: BackdropArtDownloads = .shared,
                desktop: DesktopWallpaperWatch? = nil) {
        self.maxPixelSize = max(maxPixelSize ?? Self.screenPixelSize(), 64)
        self.snapshots = snapshots
        self.downloads = downloads
        self.desktop = desktop ?? .live(defaults: nil)
    }

    /// The longest side of the largest screen, in pixels.
    static func screenPixelSize() -> Int {
        let sizes = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
        return Int((sizes.max() ?? 2560).rounded(.up))
    }

    /// The decoded image of `selection` (in light or `dark`, for one that follows the
    /// appearance), or nil until it has loaded.
    func cached(_ selection: BackdropSelection, texture: BackdropTexture = .default, dark: Bool = false) -> NSImage? {
        images[Key(id: selection.variantID(dark: dark), texture: texture)]
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

    /// Drops the decoded Desktop Wallpaper once the desktop has moved on to `generation`, so the
    /// next window to ask decodes the new picture; every later call for the same generation keeps
    /// what that first reload decoded.
    func forgetDesktopPicture(olderThan generation: Int) {
        guard generation > desktopGeneration else { return }
        desktopGeneration = generation
        images = images.filter { $0.key.id != BackdropSelection.desktopID }
        let retired = loads.filter { $0.key.id == BackdropSelection.desktopID }.map(\.value)
        loads = loads.filter { $0.key.id != BackdropSelection.desktopID }
        guard !retired.isEmpty else { return }
        let earlier = retiredDesktopLoads
        // task-owner: the chain of retired desktop decodes; it ends when they do (never cancelled)
        retiredDesktopLoads = Task.detached(priority: .utility) {
            await earlier?.value
            for load in retired { _ = await load.value }
        }
    }

    /// Starts loading `selection` so the first window that shows it finds it decoded.
    public func prewarm(_ selection: BackdropSelection?, texture: BackdropTexture = .default) {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let selection, cached(selection, texture: texture, dark: dark) == nil else { return }
        // task-owner: one load per prewarm, kept in `warming` so tests can wait for it
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
        if let image = images[key] { return image }
        if case .art(let art) = selection, art.imageURL == nil {
            // Not bundled and not downloaded yet: fetch it once, then decode as usual.
            guard await downloads.file(for: art) != nil else { return nil }
            if let image = images[key] { return image }
        }
        // Every caller waits on the newest chain until none is newer (the desktop can move on
        // again while it waits); the first to resume starts the decode, the rest join it below.
        while key.id == BackdropSelection.desktopID, loads[key] == nil, let retired = retiredDesktopLoads {
            await retired.value
            guard !Task.isCancelled else { return nil }
            if let image = images[key] { return image }
            if retiredDesktopLoads == retired { retiredDesktopLoads = nil }
        }
        let load: Task<Decoded?, Never>
        let generation = desktopGeneration
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
        if loads[key] == load { loads[key] = nil }
        // The desktop moved on while this decoded: its picture is stale, so load the new one,
        // unless the caller gave up (a newer apply cancelled its art load).
        if key.id == BackdropSelection.desktopID, generation != desktopGeneration {
            guard !Task.isCancelled else { return nil }
            return await image(selection, texture: texture, dark: dark)
        }
        if let image = images[key] { return image }
        guard let decoded else { return nil }
        if decoded.rendered { renderCount += 1 }
        let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
        images[key] = image
        return image
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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let frame = (dark ? BackdropAppearance.dark : .light).frame(in: source)
        return CGImageSourceCreateThumbnailAtIndex(source, frame, options as CFDictionary)
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
