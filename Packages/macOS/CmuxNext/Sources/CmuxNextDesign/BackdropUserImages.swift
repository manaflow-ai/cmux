public import Foundation

/// The person's own background images (cx-t2x.8): files in the backgrounds folder that are not
/// downloaded art. Choosing or dropping an image copies it there, so the background keeps working
/// after the original moves, and the picker lists it under "Your images".
public nonisolated struct BackdropUserImages: Sendable {
    /// The image types the picker and the window backdrop read.
    public static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "avif", "webp", "tif", "tiff", "gif"]

    /// The picker collection the images are listed under.
    public static let collection = "yours"

    /// The picker's title for them.
    public static var collectionTitle: String {
        String(localized: "backdrop.collection.yours", defaultValue: "Your images", bundle: .module)
    }

    /// The backgrounds folder (``BackdropArtDownloads/defaultFolder``).
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    /// Whether `url` names an image file the backdrop can show.
    public static func isImage(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// The folder's images, newest first, without downloaded art (`<art id>.avif`).
    public func list(fileManager: FileManager = .default) -> [BackdropSelection] {
        let files = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        let images: [(url: URL, modified: Date)] = files.filter { Self.isImage($0) && !isDownloadedArt($0) }.map { url in
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (url, modified ?? .distantPast)
        }
        let newestFirst = images.sorted { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        return newestFirst.map { BackdropSelection.file(path: $0.url.path) }
    }

    /// Whether `selection` is one of this folder's own images.
    public func contains(_ selection: BackdropSelection) -> Bool {
        guard case .file(let path) = selection else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.deletingLastPathComponent().path == folder.path && Self.isImage(url) && !isDownloadedArt(url)
    }

    /// Copies `source` into the folder (a free name beside any file already there) and returns
    /// it as a selection; an image already in the folder is returned as is.
    public func adopt(_ source: URL, fileManager: FileManager = .default) throws -> BackdropSelection {
        let source = source.standardizedFileURL
        guard Self.isImage(source) else { throw CocoaError(.fileReadUnsupportedScheme) }
        if source.deletingLastPathComponent().path == folder.path, !isDownloadedArt(source) {
            return .file(path: source.path)
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

    private func isDownloadedArt(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "avif" && BackdropArt(rawValue: url.deletingPathExtension().lastPathComponent) != nil
    }
}
