public import AppKit
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
/// The lookups run on the system lane (``WorkspaceQueries``), never on the
/// main thread: a row whose type was not asked yet shows a placeholder, and
/// ``arrivals`` changes when its icon lands, so the pane redraws the rows on
/// screen. Only rows on screen ask, so the visible list is what is fetched.
/// Thumbnails come from `QLThumbnailGenerator` off the main actor, only for
/// the tiles on screen, and are kept in an `NSCache` by path, size and
/// modification date.
@MainActor
@Observable
public final class FileIconProvider {
    /// Counts the icons that landed since the provider was made: a view that showed placeholders redraws its rows
    /// when it changes.
    public private(set) var arrivals = 0
    @ObservationIgnored private var typeIcons: [String: NSImage] = [:]
    @ObservationIgnored private var asking: Set<String> = []
    private let thumbnails = NSCache<NSString, NSImage>()
    @ObservationIgnored private var pending: [NSString: Task<NSImage?, Never>] = [:]
    private let queries: WorkspaceQueries?

    /// Makes a provider. One per app is enough; panes share it.
    ///
    /// - Parameter queries: The app's Launch Services answers; nil (tests) shows placeholders only.
    public init(queries: WorkspaceQueries?) {
        self.queries = queries
        thumbnails.countLimit = 2_000
    }

    /// The type icon for `entry` (folder, package, or by extension), or a placeholder until it lands.
    public func icon(for entry: FileEntry) -> NSImage {
        let key: String
        let query: WorkspaceQuery<NSImage>
        switch entry.kind {
        case .folder: (key, query) = ("/folder", WorkspaceQuery<NSImage>.typeIcon(.folder))
        case .symlink: (key, query) = ("/symlink", WorkspaceQuery<NSImage>.typeIcon(.symbolicLink))
        // Apps carry their own icons, so packages are looked up per item (rare in a folder).
        case .package: (key, query) = ("/package" + entry.url.path, WorkspaceQuery<NSImage>.fileIcon(atPath: entry.url.path))
        case .file, .other: (key, query) = (entry.pathExtension, WorkspaceQuery<NSImage>.typeIcon(UTType(filenameExtension: entry.pathExtension) ?? .data))
        }
        if let cached = typeIcons[key] { return cached }
        ask(query, for: key)
        return Self.placeholder(folder: entry.kind == .folder)
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
        thumbnails.object(forKey: Self.key(entry, size))
    }

    /// A thumbnail of `entry` at `size` points (made off the main actor, then cached).
    /// Nil for folders and when Quick Look has none.
    public func thumbnail(for entry: FileEntry, size: CGFloat, scale: CGFloat) async -> NSImage? {
        guard entry.kind == .file else { return nil }
        let key = Self.key(entry, size)
        if let cached = thumbnails.object(forKey: key) { return cached }
        if let running = pending[key] { return await running.value }
        let url = entry.url
        let task = Task<NSImage?, Never> {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                       scale: scale, representationTypes: .thumbnail)
            let cgImage = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
            return cgImage.map { NSImage(cgImage: $0, size: CGSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale)) }
        }
        pending[key] = task
        let image = await task.value
        pending[key] = nil
        if let image { thumbnails.setObject(image, forKey: key) }
        return image
    }

    /// Asks the system lane for the icon of `key` once; its landing bumps ``arrivals``.
    private func ask(_ query: WorkspaceQuery<NSImage>, for key: String) {
        guard let queries, asking.insert(key).inserted else { return }
        queries.value(query, priority: .userVisible) { [weak self] image in
            guard let self else { return }
            asking.remove(key)
            typeIcons[key] = image
            arrivals += 1
        }
    }

    /// What a row shows until its icon lands: the folder or the document symbol.
    private static func placeholder(folder: Bool) -> NSImage {
        NSImage(systemSymbolName: folder ? "folder" : "doc", accessibilityDescription: nil) ?? NSImage()
    }

    private static func key(_ entry: FileEntry, _ size: CGFloat) -> NSString {
        "\(entry.url.path)|\(Int(size))|\(entry.modified.timeIntervalSince1970)" as NSString
    }
}
