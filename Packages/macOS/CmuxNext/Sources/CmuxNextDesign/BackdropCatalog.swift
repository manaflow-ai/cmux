public import Foundation

/// The wallpaper choices displayed by Appearance settings.
public nonisolated struct BackdropCatalog: Sendable {
    /// The bundled art by collection (Dark Art, Museum Icons, Calm, Doré), then the person's own
    /// images, then the desktop picture, then every macOS wallpaper (``AppleWallpapers``).
    public let choices: [BackdropSelection]
    /// The macOS wallpapers among ``choices``, by path.
    public let appleWallpapers: [String: AppleWallpaper]

    /// The bundled art in picker order: by collection, darkest works first within each.
    public static let bundled: [BackdropSelection] = BackdropArtCollection.allCases.flatMap { collection in
        BackdropArt.allCases.filter { $0.collection == collection }.map(BackdropSelection.art)
    }

    /// Builds a catalog from an injected directory listing.
    ///
    /// - Parameters:
    ///   - systemDirectory: The macOS wallpaper directory.
    ///   - fileManager: The file manager used to enumerate it.
    ///   - assets: The macOS wallpapers downloaded in full.
    ///   - userImages: The person's own images (``BackdropUserImages``), if any.
    public init(systemDirectory: URL, fileManager: FileManager, assets: AppleWallpaperAssets = AppleWallpaperAssets(),
                userImages: BackdropUserImages? = nil) {
        let apple = AppleWallpapers(desktopPictures: systemDirectory).pictures(assets: assets, fileManager: fileManager)
        appleWallpapers = Dictionary(apple.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        choices = Self.bundled + (userImages?.list(fileManager: fileManager) ?? []) + [.desktop]
            + apple.map { BackdropSelection.system(path: $0.path) }
    }
}
