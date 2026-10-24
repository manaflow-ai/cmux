public import Foundation

/// The wallpaper choices displayed by Appearance settings.
public nonisolated struct BackdropCatalog: Equatable, Sendable {
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

    /// What the picker lists before any folder is read: the bundled art and the desktop picture.
    /// Reads no file, so it is safe on the main actor while a full catalog is built elsewhere.
    public static let unlisted = BackdropCatalog(choices: bundled + [.desktop], appleWallpapers: [:])

    private init(choices: [BackdropSelection], appleWallpapers: [String: AppleWallpaper]) {
        self.choices = choices
        self.appleWallpapers = appleWallpapers
    }

    /// Builds a catalog from an injected directory listing. It reads every macOS wallpaper
    /// description and the downloaded assets (tens of milliseconds): build it off the main actor.
    ///
    /// - Parameters:
    ///   - systemDirectory: The macOS wallpaper directory.
    ///   - fileManager: The file manager used to enumerate it.
    ///   - assets: The macOS wallpapers downloaded in full.
    ///   - userImages: The person's own images and videos (``BackdropUserImages``), if any.
    ///   - aerials: Where idleassetsd keeps downloaded aerials (``AppleWallpapers``).
    public init(systemDirectory: URL, fileManager: FileManager, assets: AppleWallpaperAssets = AppleWallpaperAssets(),
                userImages: BackdropUserImages? = nil, aerials: URL = AppleWallpapers.system.aerials) {
        let wallpapers = AppleWallpapers(desktopPictures: systemDirectory, aerials: aerials)
        let apple = wallpapers.pictures(assets: assets, fileManager: fileManager)
        appleWallpapers = Dictionary(apple.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let yours = userImages?.list(fileManager: fileManager) ?? []
        let moving = wallpapers.videos(fileManager: fileManager)
        choices = Self.bundled + yours.filter { !$0.isVideo } + [.desktop] + apple.map { BackdropSelection.system(path: $0.path) }
            + moving + yours.filter(\.isVideo)
    }
}
