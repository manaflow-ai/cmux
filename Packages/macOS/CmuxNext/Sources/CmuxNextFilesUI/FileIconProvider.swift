public import AppKit
public import CmuxNextCompat
public import CmuxNextFiles
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Icons and thumbnails for Files rows and tiles, shared by every Files and
/// Screenshots pane.
///
/// Type icons are cached per extension (one `NSWorkspace` lookup per type,
/// not per file), so a 100 000-row list asks the system a handful of times.
/// Thumbnails come from `QLThumbnailGenerator` off the main actor, only for
/// the tiles on screen, and are kept least recently used first by path, size
/// and modification date, bounded by count and by pixel bytes.
///
/// It is a ``MemoryConsumer`` (Chrome's base/memory_coordinator/memory_consumer.h)
/// once its owner calls ``registerMemoryConsumer(with:)``: the limit scales both
/// thumbnail bounds, a release drops the least recently used thumbnails down to
/// them, and at the critical limit the type icons go too. A tile or row drawn
/// after a release asks the system again. A plain `NSCache` cannot do this: it
/// reports neither its count nor its bytes, and its limit 0 means no limit.
@MainActor
public final class FileIconProvider {
    /// Draws the thumbnail of a file at a side in points and a backing scale; nil when it has none.
    public typealias Render = @Sendable (_ url: URL, _ side: CGFloat, _ scale: CGFloat) async -> CGImage?

    /// Thumbnails kept at the full memory limit.
    public static let defaultThumbnailCount = 2_000

    private var typeIcons: [String: NSImage] = [:]
    private var thumbnails: FileThumbnailStore
    private var pending: [String: Task<FileThumbnail?, Never>] = [:]
    private let render: Render
    private var memoryRegistration: MemoryConsumerRegistration?

    /// Makes a provider. One per app is enough; panes share it.
    ///
    /// - Parameters:
    ///   - thumbnailCount: Thumbnails kept at the full memory limit.
    ///   - thumbnailBytes: Their pixel bytes at the full memory limit (the composition root gives a
    ///     share of the Mac's image cache budget); nil bounds them by count alone.
    ///   - render: What draws thumbnails (Quick Look; tests pass their own).
    public init(thumbnailCount: Int = FileIconProvider.defaultThumbnailCount, thumbnailBytes: Int? = nil,
                render: @escaping Render = FileIconProvider.quickLookThumbnail) {
        thumbnails = FileThumbnailStore(maxCount: thumbnailCount, maxBytes: thumbnailBytes ?? .max)
        self.render = render
    }

    /// Quick Look's best thumbnail of `url`, at most `side` points square at `scale`.
    nonisolated public static func quickLookThumbnail(_ url: URL, side: CGFloat, scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    /// Registers with the app's memory coordinator (once; a later call replaces the registration).
    ///
    /// - Parameter registry: The memory coordinator.
    public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        memoryRegistration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    /// The type icon for `entry` (folder, package, or by extension).
    public func icon(for entry: FileEntry) -> NSImage {
        let key: String
        switch entry.kind {
        case .folder: key = "/folder"
        case .symlink: key = "/symlink"
        case .package: return packageIcon(entry)
        case .file, .other: key = entry.pathExtension
        }
        if let cached = typeIcons[key] { return cached }
        let image: NSImage
        switch entry.kind {
        case .folder: image = NSWorkspace.shared.icon(for: .folder)
        case .symlink: image = NSWorkspace.shared.icon(for: .symbolicLink)
        default: image = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        }
        typeIcons[key] = image
        return image
    }

    /// The system's localized kind for `entry` ("Folder", "PNG image").
    public func kind(for entry: FileEntry) -> String {
        switch entry.kind {
        case .folder: return UTType.folder.localizedDescription ?? ""
        case .symlink: return UTType.symbolicLink.localizedDescription ?? ""
        default: return UTType(filenameExtension: entry.pathExtension)?.localizedDescription ?? UTType.data.localizedDescription ?? ""
        }
    }

    /// A cached thumbnail of `entry` at `size` points, or nil when none is made yet.
    public func cachedThumbnail(for entry: FileEntry, size: CGFloat) -> NSImage? {
        thumbnails.image(for: Self.key(entry, size))
    }

    /// A thumbnail of `entry` at `size` points (made off the main actor, then cached).
    /// Nil for folders and when Quick Look has none.
    public func thumbnail(for entry: FileEntry, size: CGFloat, scale: CGFloat) async -> NSImage? {
        guard entry.kind == .file else { return nil }
        let key = Self.key(entry, size)
        if let cached = thumbnails.image(for: key) { return cached }
        if let running = pending[key] { return await running.value?.image }
        let url = entry.url
        let render = render
        let task = Task<FileThumbnail?, Never> {
            await render(url, size, scale).map { FileThumbnail($0, scale: scale) }
        }
        pending[key] = task
        let thumbnail = await task.value
        pending[key] = nil
        if let thumbnail { thumbnails.insert(thumbnail, for: key) }
        return thumbnail?.image
    }

    private func packageIcon(_ entry: FileEntry) -> NSImage {
        // Apps carry their own icons, so packages are looked up per item (rare in a folder).
        let key = "/package" + entry.url.path
        if let cached = typeIcons[key] { return cached }
        let image = NSWorkspace.shared.icon(forFile: entry.url.path)
        typeIcons[key] = image
        return image
    }

    private static func key(_ entry: FileEntry, _ size: CGFloat) -> String {
        "\(entry.url.path)|\(Int(size))|\(entry.modified.timeIntervalSince1970)"
    }
}

/// The thumbnails and type icons are one lossless consumer: each comes back from Quick Look or
/// `NSWorkspace` the next time a row or tile draws it. A tile on screen keeps the picture it shows;
/// only the cache behind it shrinks.
extension FileIconProvider: MemoryConsumer {
    /// Nothing to write back, but a Quick Look render each to make again: warning pressure leaves it
    /// whole and critical pressure empties it.
    public static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .medium,
        dataAccess: .none,
        retention: .lossless,
        recreateCost: .expensive,
        releaseCPUCost: .low,
        isStateful: true,
        supportsMemoryLimit: true
    )

    /// The consumer's name in the memory report.
    public static let memoryConsumerName = "files-thumbnails"

    /// Scales both thumbnail bounds; frees nothing (the next thumbnail drops the oldest past them).
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        thumbnails.setLimits(count: limit.scale(thumbnails.maxCount), bytes: limit.scale(thumbnails.maxBytes))
    }

    /// Drops least recently used thumbnails until both bounds hold or the slice ends; at the
    /// critical limit then the type icons.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        guard thumbnails.trim(until: { slice.isExpired }) else { return .more }
        if slice.limit.isCritical { typeIcons.removeAll() }
        return .done
    }

    /// Thumbnail pixel bytes from a counter; the entries are the thumbnails and the type icons.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: thumbnails.bytes, entries: thumbnails.count + typeIcons.count)
    }
}

/// One thumbnail and its pixel bytes.
private nonisolated struct FileThumbnail: Sendable {
    let image: NSImage
    let bytes: Int

    /// `cgImage` shown at `scale` pixels per point.
    init(_ cgImage: CGImage, scale: CGFloat) {
        image = NSImage(cgImage: cgImage, size: CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        bytes = cgImage.bytesPerRow * cgImage.height
    }
}

/// The thumbnails, least recently used first, within a count bound and a pixel byte bound that
/// the memory limit lowers. Hits and inserts are O(1); an eviction sorts once and drops down to
/// seven eighths of each bound, so a scroll does not sort per thumbnail.
private struct FileThumbnailStore {
    private struct Entry {
        let thumbnail: FileThumbnail
        var used: UInt64
    }

    /// The bounds at the full memory limit.
    let maxCount: Int
    let maxBytes: Int
    /// The bounds the memory limit allows now.
    private(set) var countLimit: Int
    private(set) var byteLimit: Int
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    /// The pixel bytes held, kept on every insert and removal.
    private(set) var bytes = 0

    init(maxCount: Int, maxBytes: Int) {
        self.maxCount = max(0, maxCount)
        self.maxBytes = max(0, maxBytes)
        countLimit = self.maxCount
        byteLimit = self.maxBytes
    }

    var count: Int { entries.count }

    /// The image under `key`, now the most recently used.
    mutating func image(for key: String) -> NSImage? {
        guard entries[key] != nil else { return nil }
        clock += 1
        entries[key]?.used = clock
        return entries[key]?.thumbnail.image
    }

    /// Keeps `thumbnail` within the bounds: at a count bound of 0, or over the byte bound alone,
    /// it keeps nothing.
    mutating func insert(_ thumbnail: FileThumbnail, for key: String) {
        guard countLimit > 0, thumbnail.bytes <= byteLimit else { return }
        clock += 1
        bytes += thumbnail.bytes - (entries[key]?.thumbnail.bytes ?? 0)
        entries[key] = Entry(thumbnail: thumbnail, used: clock)
        guard isOverLimits else { return }
        let countTarget = countLimit - countLimit / 8
        let byteTarget = byteLimit - byteLimit / 8
        for key in oldestKeys() where entries.count > countTarget || bytes > byteTarget { remove(key) }
    }

    /// New bounds, clamped to the full ones. Frees nothing.
    mutating func setLimits(count: Int, bytes: Int) {
        countLimit = min(max(count, 0), maxCount)
        byteLimit = min(max(bytes, 0), maxBytes)
    }

    /// Drops the least recently used thumbnails until both bounds hold, checking `isExpired` before
    /// each. True when the bounds hold.
    mutating func trim(until isExpired: () -> Bool) -> Bool {
        guard isOverLimits else { return true }
        for key in oldestKeys() {
            guard isOverLimits else { return true }
            if isExpired() { return false }
            remove(key)
        }
        return !isOverLimits
    }

    private var isOverLimits: Bool { entries.count > countLimit || bytes > byteLimit }

    private func oldestKeys() -> [String] {
        entries.sorted { $0.value.used < $1.value.used }.map(\.key)
    }

    private mutating func remove(_ key: String) {
        bytes -= entries.removeValue(forKey: key)?.thumbnail.bytes ?? 0
    }
}
