import CmuxNextCompat
public import Foundation

/// The wallpapers macOS ships, read where macOS keeps them; cmux copies none.
///
/// - Stills (``pictures(assets:)``): every picture and `.madesktop` description in
///   the Desktop Pictures folder, in the Wallpaper pane's order (``AppleWallpaper``), for the
///   picker's Apple Wallpapers group.
/// - Moving wallpapers (cx-14vdf, ``videos()``):
///   `/System/Library/Desktop Pictures/.wallpapers/<name>/*.mov`, the shipped moving wallpapers
///   (Sonoma) in a light and a dark cut, the window playing the cut for its appearance; and the
///   aerials idleassetsd downloaded (`Customer/**/*.mov`, named by `entries.json`).
public nonisolated struct AppleWallpapers: Sendable {
    /// `/System/Library/Desktop Pictures`.
    public let desktopPictures: URL
    /// Where idleassetsd keeps downloaded aerials.
    public let aerials: URL

    public static let systemAerials = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true)

    public static let system = AppleWallpapers(
        desktopPictures: URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
        aerials: systemAerials)

    /// The Wallpaper pane of System Settings, where macOS downloads a wallpaper the picker lists
    /// as not downloaded (`cmux.settings.backdrop.wallpaper_settings`).
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")

    /// The picker collection of the stills.
    public static let collection = "apple"

    /// The picker's title for them.
    public static var collectionTitle: String {
        String(localized: "backdrop.collection.apple", defaultValue: "Apple Wallpapers", bundle: .module)
    }

    /// The picker collection of every moving wallpaper.
    public static let videoCollection = "video"

    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    public init(desktopPictures: URL, aerials: URL = Self.systemAerials) {
        self.desktopPictures = desktopPictures
        self.aerials = aerials
    }

    /// Every still wallpaper in ``desktopPictures``.
    ///
    /// - Parameters:
    ///   - assets: The downloaded full pictures.
    public func pictures(assets: AppleWallpaperAssets = AppleWallpaperAssets()) -> [AppleWallpaper] {
        func list(_ folder: URL) -> [URL] {
            (try? FileManager.checked.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
        let top = list(desktopPictures)
        var files = top.filter { !isFolder($0) }
        for folder in top where isFolder(folder) { files += list(folder).filter { !isFolder($0) } }
        for folder in list(desktopPictures.appendingPathComponent(".wallpapers", isDirectory: true)) where isFolder(folder) {
            // A moving wallpaper's folder also holds its movies and small thumbnails.
            files += list(folder).filter { ["heic", "heif"].contains($0.pathExtension.lowercased()) }
        }
        let order = FileManager.checked.contents(atPath: desktopPictures.appendingPathComponent(".orderedPictures.plist").path)
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String] } ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return files.compactMap { AppleWallpaper(path: $0.path, assets: assets) }
            .sorted { a, b in
                let ra = rank[URL(fileURLWithPath: a.path).lastPathComponent] ?? Int.max
                let rb = rank[URL(fileURLWithPath: b.path).lastPathComponent] ?? Int.max
                if ra != rb { return ra < rb }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }

    /// Every moving wallpaper on disk: one per shipped wallpaper (its light cut, or its only one),
    /// then the downloaded aerials.
    public func videos() -> [BackdropSelection] {
        let shipped = Self.files(in: desktopPictures.appendingPathComponent(".wallpapers"))
            .flatMap { Self.files(in: $0) }
            .filter { Self.isVideo($0.path) && !$0.lastPathComponent.contains("Portrait") }
            .filter { !$0.lastPathComponent.contains(" Dark ") || !FileManager.checked.fileExists(atPath: Self.cut($0.path, dark: false)) }
        let downloaded = Self.files(in: aerials)
            .flatMap { Self.isVideo($0.path) ? [$0] : Self.files(in: $0) }
            .filter { Self.isVideo($0.path) }
        return (Self.byName(shipped) + Self.byName(downloaded)).map { .system(path: $0.path) }
    }

    /// The aerials' names from idleassetsd's `entries.json`, by asset id.
    public func aerialNames() -> [String: String] {
        struct Entries: Decodable {
            struct Asset: Decodable {
                let id: String
                let accessibilityLabel: String?
            }
            let assets: [Asset]
        }
        guard let data = try? Data(contentsOf: aerials.appendingPathComponent("entries.json")),
              let entries = try? JSONDecoder().blockingDecode(Entries.self, from: data) else { return [:] }
        return Dictionary(entries.assets.compactMap { asset in asset.accessibilityLabel.map { (asset.id, $0) } }) { first, _ in first }
    }

    /// Whether `path` names a video.
    public static func isVideo(_ path: String) -> Bool {
        videoExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Whether `path` is a shipped moving wallpaper with a light and a dark cut.
    public static func hasCuts(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return isVideo(path) && (name.contains(" Light ") || name.contains(" Dark "))
    }

    /// The file a window plays for `path` in light or dark: a shipped wallpaper's cut for the
    /// appearance when macOS has it, any other file itself.
    public static func file(for path: String, dark: Bool) -> URL {
        let cut = cut(path, dark: dark)
        return URL(fileURLWithPath: hasCuts(path) && FileManager.default.fileExists(atPath: cut) ? cut : path)
    }

    /// A shipped video's light or dark cut (`Sonoma Graphic Light Landscape.mov`).
    static func cut(_ path: String, dark: Bool) -> String {
        // Only the file name: a folder named " Dark " is not a cut.
        let url = URL(fileURLWithPath: path), name = url.lastPathComponent
        let swapped = dark ? name.replacingOccurrences(of: " Light ", with: " Dark ") : name.replacingOccurrences(of: " Dark ", with: " Light ")
        return url.deletingLastPathComponent().appendingPathComponent(swapped).path
    }

    /// A folder's entries, hidden ones included (`.wallpapers` is hidden).
    private static func files(in folder: URL) -> [URL] {
        (try? FileManager.checked.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    private static func byName(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
