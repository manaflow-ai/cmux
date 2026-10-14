public import Foundation

/// The wallpapers macOS ships, read where macOS keeps them; cmux copies none.
///
/// ``pictures(assets:fileManager:)`` lists every still in the Desktop Pictures folder, in the
/// Wallpaper pane's order (`.orderedPictures.plist`), then by name: the pictures and `.madesktop`
/// descriptions at its top, the pictures in its folders (Solid Colors), and the still pictures of
/// `.wallpapers` (``AppleWallpaper``).
public nonisolated struct AppleWallpapers: Sendable {
    /// `/System/Library/Desktop Pictures`.
    public let desktopPictures: URL

    public static let system = AppleWallpapers(
        desktopPictures: URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true))

    /// The Wallpaper pane of System Settings, where macOS downloads a wallpaper the picker lists
    /// as not downloaded (`cmux.settings.backdrop.wallpaper_settings`).
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")

    /// The picker collection of the stills.
    public static let collection = "apple"

    /// The picker's title for them.
    public static var collectionTitle: String {
        String(localized: "backdrop.collection.apple", defaultValue: "Apple Wallpapers", bundle: .module)
    }

    public init(desktopPictures: URL) {
        self.desktopPictures = desktopPictures
    }

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
