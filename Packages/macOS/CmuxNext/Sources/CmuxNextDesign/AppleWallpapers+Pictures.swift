public import CmuxNextAppearance
public import Foundation

/// The macOS still wallpapers as the picker lists them (``AppleWallpaper``: its light and dark
/// frames and its thumbnail).
nonisolated extension AppleWallpapers {
    /// Every still wallpaper in ``desktopPictures``.
    ///
    /// - Parameters:
    ///   - assets: The downloaded full pictures.
    ///   - fileManager: Lists the folder.
    public func pictures(assets: AppleWallpaperAssets = AppleWallpaperAssets(), fileManager: FileManager = .default) -> [AppleWallpaper] {
        func list(_ folder: URL) -> [URL] {
            (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
        let top = list(desktopPictures)
        var files = top.filter { !isFolder($0) }
        for folder in top where isFolder(folder) { files += list(folder).filter { !isFolder($0) } }
        for folder in list(desktopPictures.appendingPathComponent(".wallpapers", isDirectory: true)) where isFolder(folder) {
            // A moving wallpaper's folder also holds its movies and small thumbnails.
            files += list(folder).filter { ["heic", "heif"].contains($0.pathExtension.lowercased()) }
        }
        let order = fileManager.contents(atPath: desktopPictures.appendingPathComponent(".orderedPictures.plist").path)
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String] } ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return files.compactMap { AppleWallpaper(path: $0.path, assets: assets, fileManager: fileManager) }
            .sorted { a, b in
                let ra = rank[URL(fileURLWithPath: a.path).lastPathComponent] ?? Int.max
                let rb = rank[URL(fileURLWithPath: b.path).lastPathComponent] ?? Int.max
                if ra != rb { return ra < rb }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }
}
