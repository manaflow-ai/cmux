public import Foundation

/// The wallpaper choices displayed by Appearance settings.
public nonisolated struct BackdropCatalog: Sendable, Equatable {
    /// The bundled art by collection (Dark Art, Museum Icons, Calm, Doré), then the person's own
    /// images, then the desktop picture, then every macOS wallpaper (``AppleWallpapers``), then the
    /// moving wallpapers (Apple's and downloaded aerials, then the person's own videos).
    public let choices: [BackdropSelection]
    /// The macOS wallpapers among ``choices``, by path.
    public let appleWallpapers: [String: AppleWallpaper]

    /// The bundled art in picker order: by collection, darkest works first within each.
    public static let bundled: [BackdropSelection] = BackdropArtCollection.allCases.flatMap { collection in
        BackdropArt.allCases.filter { $0.collection == collection }.map(BackdropSelection.art)
    }

    /// The bundled art only (no folder read): what ``BackdropCatalogStore`` shows before its first build.
    public init(bundledOnly: Void) {
        choices = Self.bundled
        appleWallpapers = [:]
    }

    /// Builds a catalog from an injected directory listing.
    ///
    /// - Parameters:
    ///   - systemDirectory: The macOS wallpaper directory.
    ///   - assets: The macOS wallpapers downloaded in full.
    ///   - userImages: The person's own images and videos (``BackdropUserImages``), if any.
    ///   - aerials: Where idleassetsd keeps downloaded aerials (``AppleWallpapers``).
    public init(systemDirectory: URL, assets: AppleWallpaperAssets = AppleWallpaperAssets(),
                userImages: BackdropUserImages? = nil, aerials: URL = AppleWallpapers.system.aerials) {
        let wallpapers = AppleWallpapers(desktopPictures: systemDirectory, aerials: aerials)
        let apple = wallpapers.pictures(assets: assets)
        appleWallpapers = Dictionary(apple.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let yours = userImages?.list() ?? []
        let moving = wallpapers.videos()
        choices = Self.bundled + yours.filter { !$0.isVideo } + [.desktop] + apple.map { BackdropSelection.system(path: $0.path) }
            + moving + yours.filter(\.isVideo)
    }
}
