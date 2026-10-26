public import AppKit
public import CmuxNextCompat
public import CmuxNextFiles
public import CmuxNextWakeups
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Icons and thumbnails for Files rows and tiles, shared by every Files and
/// Screenshots pane.
///
/// Type icons are cached per extension (one Launch Services lookup per type,
/// not per file), so a 100 000-row list asks the system a handful of times.
/// Package icons (apps carry their own) are kept per package, least recently
/// used first, within a count bound. The icon lookups run on the system lane
/// (``WorkspaceQueries``), never on the main thread: a row whose icon was not
/// asked yet shows a placeholder, and ``arrivals`` changes when its icon lands,
/// so the pane redraws the rows on screen. Only rows on screen ask, so the
/// visible list is what is fetched. Thumbnails come from `QLThumbnailGenerator`
/// off the main actor, only for the tiles on screen, and are kept least
/// recently used first by path, size and modification date, bounded by count
/// and by pixel bytes (a share of the Mac's image cache budget).
///
/// It is a ``MemoryConsumer`` (Chrome's base/memory_coordinator/memory_consumer.h)
/// once its owner calls ``registerMemoryConsumer(with:)``: the limit scales the
/// bounds, a release drops the least recently used down to them, and at the
/// critical limit the type icons go too. The newest ``defaultWorkingSet``
/// thumbnails and package icons, about a screenful, are the working set and stay
/// at every limit (p07-memory.md section 3.A), so a grid reloaded under critical
/// pressure shows its tiles without a Quick Look render each. A plain `NSCache`
/// cannot do this: it reports neither its count nor its bytes, and its limit 0
/// means no limit.
@MainActor
@Observable
public final class FileIconProvider {
    /// Draws the thumbnail of a file at a side in points and a backing scale; nil when it has none.
    public typealias Render = @Sendable (_ url: URL, _ side: CGFloat, _ scale: CGFloat) async -> CGImage?

    /// Thumbnails kept at the full memory limit.
    public static let defaultThumbnailCount = 2_000
    /// Their pixel bytes at the full memory limit when the owner gives none: 32 MiB, the quarter of
    /// the image cache budget of a 16 GB Mac.
    public static let defaultThumbnailBytes = 32 << 20
    /// Package icons kept at the full memory limit.
    public static let defaultPackageIconCount = 256
    /// The newest thumbnails (and package icons) every limit keeps: about one screenful.
    public static let defaultWorkingSet = 64
    /// The estimated bytes of one system icon as a row draws it (32 points at 2x, 4 bytes a pixel).
    public static let iconBytes = 64 * 64 * 4

    /// Counts the icons that landed since the provider was made: a view that showed placeholders redraws its rows
    /// when it changes.
    public private(set) var arrivals = 0
    @ObservationIgnored private var typeIcons: [String: NSImage] = [:]
    @ObservationIgnored private var packageIcons: FileImageStore
    @ObservationIgnored private var thumbnails: FileImageStore
    @ObservationIgnored private var pending: [String: Task<FileImage?, Never>] = [:]
    /// The icons on the system lane, by key.
    @ObservationIgnored private var asking: Set<String> = []
    private let render: Render
    private let queries: WorkspaceQueries?
    @ObservationIgnored private var memoryRegistration: MemoryConsumerRegistration?

    /// Makes a provider. One per app is enough; panes share it.
    ///
    /// - Parameters:
    ///   - queries: The app's Launch Services answers, which read the icons; nil (tests) shows placeholders only.
    ///   - thumbnailCount: Thumbnails kept at the full memory limit.
    ///   - thumbnailBytes: Their pixel bytes at the full memory limit (the composition root gives a
    ///     share of the Mac's image cache budget).
    ///   - workingSet: The newest thumbnails and package icons kept at every limit.
    ///   - render: What draws thumbnails (Quick Look; tests pass their own).
    public init(queries: WorkspaceQueries? = nil, thumbnailCount: Int = FileIconProvider.defaultThumbnailCount,
                thumbnailBytes: Int = FileIconProvider.defaultThumbnailBytes,
                workingSet: Int = FileIconProvider.defaultWorkingSet,
                render: @escaping Render = FileIconProvider.quickLookThumbnail) {
        thumbnails = FileImageStore(maxCount: thumbnailCount, maxBytes: thumbnailBytes, workingSet: workingSet)
        packageIcons = FileImageStore(maxCount: Self.defaultPackageIconCount, maxBytes: .max, workingSet: workingSet)
        self.render = render
        self.queries = queries
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

    /// The pixel bytes the thumbnails may hold now (beyond the working set).
    public var thumbnailByteLimit: Int { thumbnails.byteLimit }

    /// The type icon for `entry` (folder, package, or by extension), or a placeholder until it lands.
    public func icon(for entry: FileEntry) -> NSImage {
        let key: String
        let type: UTType
        switch entry.kind {
        case .folder: (key, type) = ("/folder", .folder)
        case .symlink: (key, type) = ("/symlink", .symbolicLink)
        case .package: return packageIcon(entry)
        case .file, .other: (key, type) = (entry.pathExtension, UTType(filenameExtension: entry.pathExtension) ?? .data)
        }
        if let cached = typeIcons[key] { return cached }
        ask(WorkspaceQuery<NSImage>.typeIcon(type).unkept, key: key) { [weak self] in self?.typeIcons[key] = $0 }
        return typeIcons[key] ?? Self.placeholder(folder: entry.kind == .folder)
    }

    /// The icon of the item at `url`, its own as Finder's Get Info shows it, given to `apply` in this turn when kept,
    /// else when it lands from the system lane.
    public func fileIcon(at url: URL, apply: @escaping @MainActor (NSImage) -> Void) {
        queries?.value(WorkspaceQuery<NSImage>.fileIcon(atPath: url.path, side: 48), priority: .userBlocking, then: apply)
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
        let task = Task<FileImage?, Never> {
            await render(url, size, scale).map { FileImage($0, scale: scale) }
        }
        pending[key] = task
        let thumbnail = await task.value
        pending[key] = nil
        if let thumbnail { thumbnails.insert(thumbnail, for: key) }
        return thumbnail?.image
    }

    private func packageIcon(_ entry: FileEntry) -> NSImage {
        // Apps carry their own icons, so packages are looked up per item.
        let key = entry.url.path
        if let cached = packageIcons.image(for: key) { return cached }
        ask(WorkspaceQuery<NSImage>.fileIcon(atPath: key).unkept, key: "/package" + key) { [weak self] image in
            self?.packageIcons.insert(FileImage(image: image, bytes: Self.iconBytes), for: key)
        }
        return packageIcons.image(for: key) ?? Self.placeholder(folder: false)
    }

    /// Asks the system lane once per `key`; `keep` puts the answer in this provider's own store when it lands (the
    /// query is unkept, so the provider is the image's one owner and its memory release frees it), then ``arrivals``
    /// moves.
    private func ask(_ query: WorkspaceQuery<NSImage>, key: String, keep: @escaping @MainActor (NSImage) -> Void) {
        guard let queries else { return }
        guard asking.insert(key).inserted else { return }
        queries.value(query, priority: .userVisible) { [weak self] image in
            guard let self else { return }
            asking.remove(key)
            keep(image)
            arrivals += 1
        }
    }

    /// What a row shows until its icon lands: the folder or the document symbol.
    private static func placeholder(folder: Bool) -> NSImage {
        NSImage(systemSymbolName: folder ? "folder" : "doc", accessibilityDescription: nil) ?? NSImage()
    }

    private static func key(_ entry: FileEntry, _ size: CGFloat) -> String {
        "\(entry.url.path)|\(Int(size))|\(entry.modified.timeIntervalSince1970)"
    }
}

/// The thumbnails and icons are one lossless consumer: each comes back from Quick Look or
/// `NSWorkspace` the next time a row or tile draws it. The working set stays at every limit.
extension FileIconProvider: MemoryConsumer {
    /// Nothing to write back, but a Quick Look render each to make again: warning pressure leaves it
    /// whole and critical pressure empties it down to its working set.
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

    /// Scales the thumbnail and package icon bounds; frees nothing (the next insert drops the oldest
    /// past them).
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        thumbnails.setLimits(limit)
        packageIcons.setLimits(limit)
    }

    /// Drops least recently used thumbnails, then package icons, until the bounds hold or the slice
    /// ends; at the critical limit then the type icons.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        guard thumbnails.trim(until: { slice.isExpired }), packageIcons.trim(until: { slice.isExpired }) else { return .more }
        if slice.limit.isCritical { typeIcons.removeAll() }
        return .done
    }

    /// Thumbnail pixel bytes from a counter plus the icons' estimated bytes; the entries are the
    /// thumbnails and the icons.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: thumbnails.bytes + packageIcons.bytes + typeIcons.count * Self.iconBytes,
                    entries: thumbnails.count + packageIcons.count + typeIcons.count)
    }
}

/// One image and its bytes.
private nonisolated struct FileImage: Sendable {
    let image: NSImage
    let bytes: Int

    init(image: NSImage, bytes: Int) {
        self.image = image
        self.bytes = bytes
    }

    /// `cgImage` shown at `scale` pixels per point; its bytes are its pixel bytes.
    init(_ cgImage: CGImage, scale: CGFloat) {
        image = NSImage(cgImage: cgImage, size: CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        bytes = cgImage.bytesPerRow * cgImage.height
    }
}

/// Images, least recently used first, within a count bound and a byte bound that the memory limit
/// lowers. The newest `workingSet` stay whatever the bounds. Hits and inserts are O(1); an eviction
/// sorts once and drops down to seven eighths of each bound, so a scroll does not sort per image.
private struct FileImageStore {
    private struct Entry {
        let image: FileImage
        var used: UInt64
    }

    /// The bounds at the full memory limit.
    let maxCount: Int
    let maxBytes: Int
    /// The newest images kept at every limit (at most `maxCount`).
    let workingSet: Int
    /// The bounds the memory limit allows now.
    private(set) var countLimit: Int
    private(set) var byteLimit: Int
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    /// The bytes held, kept on every insert and removal.
    private(set) var bytes = 0

    init(maxCount: Int, maxBytes: Int, workingSet: Int) {
        self.maxCount = max(0, maxCount)
        self.maxBytes = max(0, maxBytes)
        self.workingSet = min(max(0, workingSet), self.maxCount)
        countLimit = self.maxCount
        byteLimit = self.maxBytes
    }

    var count: Int { entries.count }

    /// The image under `key`, now the most recently used.
    mutating func image(for key: String) -> NSImage? {
        guard entries[key] != nil else { return nil }
        clock += 1
        entries[key]?.used = clock
        return entries[key]?.image.image
    }

    /// Keeps `image` (it is drawn now) unless it alone is over the full byte bound, then drops the
    /// least recently used past the bounds, never below the working set.
    mutating func insert(_ image: FileImage, for key: String) {
        guard maxCount > 0, image.bytes <= maxBytes else { return }
        clock += 1
        bytes += image.bytes - (entries[key]?.image.bytes ?? 0)
        entries[key] = Entry(image: image, used: clock)
        guard isOverLimits else { return }
        let countTarget = countLimit - countLimit / 8
        let byteTarget = byteLimit - byteLimit / 8
        for key in oldestKeys() where entries.count > workingSet && (entries.count > countTarget || bytes > byteTarget) {
            remove(key)
        }
    }

    /// The bounds `limit` allows. Frees nothing.
    mutating func setLimits(_ limit: MemoryLimit) {
        countLimit = limit.scale(maxCount)
        byteLimit = limit.scale(maxBytes)
    }

    /// Drops the least recently used images until the bounds hold, checking `isExpired` before each.
    /// True when the bounds hold.
    mutating func trim(until isExpired: () -> Bool) -> Bool {
        guard isOverLimits else { return true }
        for key in oldestKeys() {
            guard isOverLimits else { return true }
            if isExpired() { return false }
            remove(key)
        }
        return !isOverLimits
    }

    /// Over a bound, with more than the working set left to drop.
    private var isOverLimits: Bool { entries.count > workingSet && (entries.count > countLimit || bytes > byteLimit) }

    private func oldestKeys() -> [String] {
        entries.sorted { $0.value.used < $1.value.used }.map(\.key)
    }

    private mutating func remove(_ key: String) {
        bytes -= entries.removeValue(forKey: key)?.image.bytes ?? 0
    }
}
