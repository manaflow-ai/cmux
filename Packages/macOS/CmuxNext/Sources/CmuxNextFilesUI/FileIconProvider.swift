public import AppKit
public import CmuxNextFiles
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Icons and thumbnails for Files rows and tiles, shared by every Files and
/// Screenshots pane.
///
/// Type icons are cached per extension (one `NSWorkspace` lookup per type,
/// not per file), so a 100 000-row list asks the system a handful of times.
/// Thumbnails come from `QLThumbnailGenerator` off the main actor, only for
/// the tiles on screen, and are kept in an `NSCache` by path, size and
/// modification date.
@MainActor
public final class FileIconProvider {
    private var typeIcons: [String: NSImage] = [:]
    private let thumbnails = NSCache<NSString, NSImage>()
    private var pending: [NSString: Task<NSImage?, Never>] = [:]

    /// Makes a provider. One per app is enough; panes share it.
    public init() {
        thumbnails.countLimit = 2_000
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

    private func packageIcon(_ entry: FileEntry) -> NSImage {
        // Apps carry their own icons, so packages are looked up per item (rare in a folder).
        let key = "/package" + entry.url.path
        if let cached = typeIcons[key] { return cached }
        let image = NSWorkspace.shared.icon(forFile: entry.url.path)
        typeIcons[key] = image
        return image
    }

    private static func key(_ entry: FileEntry, _ size: CGFloat) -> NSString {
        "\(entry.url.path)|\(Int(size))|\(entry.modified.timeIntervalSince1970)" as NSString
    }
}
