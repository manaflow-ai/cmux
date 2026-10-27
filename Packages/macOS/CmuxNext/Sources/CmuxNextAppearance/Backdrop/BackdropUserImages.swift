public import Foundation

/// The person's own background images (cx-t2x.8): files in the backgrounds folder that are not
/// downloaded art. Choosing or dropping an image copies it there, so the background keeps working
/// after the original moves, and the picker lists it under "Your images".
public nonisolated struct BackdropUserImages: Sendable {
    /// The movie types the window backdrop loops: the person's own, Apple's shipped wallpapers and
    /// aerials (`AppleWallpapers.videoExtensions`).
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// The image and video types the picker and the window backdrop read; a video loops (cx-14vdf).
    public static let extensions = Set(["jpg", "jpeg", "png", "heic", "heif", "avif", "webp", "tif", "tiff", "gif"])
        .union(videoExtensions)

    /// The picker collection the images are listed under.
    public static let collection = "yours"

    /// The picker's title for them.
    public static var collectionTitle: String {
        String(localized: "backdrop.collection.yours", defaultValue: "Your images", bundle: .module)
    }

    /// The backgrounds folder (``BackdropArtDownloads/defaultFolder``).
    public let folder: URL

    public init(folder: URL) {
        // Resolved (links followed, `/private` dropped as Foundation does), so every path this
        // type names is spelled one way.
        self.folder = folder.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Whether `url` names an image file the backdrop can show.
    public static func isImage(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// The folder's images, newest first, without downloaded art (`<art id>.avif`).
    public func list(fileManager: FileManager = .default) -> [BackdropSelection] {
        let files = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let images: [(url: URL, modified: Date)] = files.filter { Self.isImage($0) && !isDownloadedArt($0) && Self.isPlainFile($0) }.map { url in
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (url, modified ?? .distantPast)
        }
        let newestFirst = images.sorted { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        // Named from `folder`: a listing says /private/var where the resolved folder says /var.
        return newestFirst.map { BackdropSelection.file(path: folder.appendingPathComponent($0.url.lastPathComponent).path) }
    }

    /// Whether `selection` is one of this folder's own images: a plain file directly in the folder,
    /// named without `..` or a symbolic link, so its id cannot reach a file elsewhere.
    public func contains(_ selection: BackdropSelection) -> Bool {
        guard case .file(let path) = selection else { return false }
        let url = URL(fileURLWithPath: path)
        guard url.resolvingSymlinksInPath().path == path, url.deletingLastPathComponent().path == folder.path else { return false }
        return Self.isImage(url) && !isDownloadedArt(url) && Self.isPlainFile(url)
    }

    /// A regular file, not a symbolic link or a folder named like an image.
    private static func isPlainFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    /// Copies `source` (the file a link points at) into the folder under a free name and returns
    /// it as a selection. An image already in the folder, or one whose copy is already there, is
    /// returned as is, so choosing the same image again adds nothing.
    public func adopt(_ source: URL, fileManager: FileManager = .default) throws -> BackdropSelection {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isImage(source), Self.isPlainFile(source) else { throw CocoaError(.fileReadUnsupportedScheme) }
        if source.deletingLastPathComponent().path == folder.path, !isDownloadedArt(source) {
            return .file(path: source.path)
        }
        if let copy = list(fileManager: fileManager).first(where: { selection in
            guard case .file(let path) = selection else { return false }
            return fileManager.contentsEqual(atPath: path, andPath: source.path)
        }) {
            return copy
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.lowercased()
        var target = folder.appendingPathComponent("\(name).\(ext)")
        var copy = 2
        while fileManager.fileExists(atPath: target.path) || isDownloadedArt(target) {
            target = folder.appendingPathComponent("\(name) \(copy).\(ext)")
            copy += 1
        }
        try fileManager.copyItem(at: source, to: target)
        return .file(path: target.path)
    }

    /// A downloaded work, including one since taken out of the set (``BackdropArt/removedIDs``): its
    /// file stays in the folder but is never one of the person's own images.
    private func isDownloadedArt(_ url: URL) -> Bool {
        let id = url.deletingPathExtension().lastPathComponent
        return url.pathExtension.lowercased() == "avif" && (BackdropArt(id: id) != nil || BackdropArt.removedIDs.contains(id))
    }
}
