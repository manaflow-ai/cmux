public import Foundation

/// One macOS wallpaper as the Wallpaper pane lists it: a picture file in Desktop Pictures, or a
/// `.madesktop` description of one that macOS downloads when the person first picks it. Read
/// through public file APIs only; nothing is copied into cmux.
///
/// A `.madesktop` file is a property list naming its `thumbnailPath` (a small HEIC in
/// `.thumbnails`, with `<name> Light` and `<name> Dark` variants for a dynamic wallpaper) and its
/// `mobileAssetID`, the name of the full picture in the downloaded assets.
public nonisolated struct AppleWallpaper: Equatable, Hashable, Sendable {
    /// The file the picker lists: a picture or a `.madesktop` description.
    public let path: String
    /// The wallpaper's name.
    public let title: String
    /// A small picture that is always here.
    public let thumbnail: URL
    /// The thumbnail for each appearance of a dynamic wallpaper, when macOS ships them.
    public let lightThumbnail: URL?
    public let darkThumbnail: URL?
    /// The full picture; nil until the person downloads it in System Settings.
    public let fullResolution: URL?
    /// Changes with the appearance (light and dark) or the sun.
    public let isDynamic: Bool

    /// Whether the full picture is on this Mac.
    public var isDownloaded: Bool { fullResolution != nil }

    /// The picture a window shows for `appearance`: the full one, else the thumbnail meanwhile.
    public func imageURL(for appearance: BackdropAppearance) -> URL {
        if let fullResolution { return fullResolution }
        return (appearance == .dark ? darkThumbnail : lightThumbnail) ?? thumbnail
    }

    /// Reads the wallpaper at `path`; nil when it is neither a picture nor a readable description.
    ///
    /// - Parameters:
    ///   - path: A picture or `.madesktop` file.
    ///   - assets: The downloaded full pictures, by asset name.
    ///   - fileManager: Checks which thumbnails exist.
    public init?(path: String, assets: AppleWallpaperAssets, fileManager: FileManager = .default) {
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        let thumbnails = Self.thumbnailFolder(for: url)
        func variant(_ base: URL, _ suffix: String) -> URL? {
            let file = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.deletingPathExtension().lastPathComponent) \(suffix).\(base.pathExtension)")
            return fileManager.fileExists(atPath: file.path) ? file : nil
        }
        self.path = path
        title = name
        if url.pathExtension.lowercased() == "madesktop" {
            guard let data = fileManager.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let thumbnailPath = plist["thumbnailPath"] as? String, thumbnailPath.hasPrefix("/") else { return nil }
            let thumbnail = URL(fileURLWithPath: thumbnailPath)
            isDynamic = plist["isDynamic"] as? Bool ?? false
            self.thumbnail = thumbnail
            lightThumbnail = isDynamic ? variant(thumbnail, "Light") : nil
            darkThumbnail = isDynamic ? variant(thumbnail, "Dark") : nil
            fullResolution = assets.file(named: plist["mobileAssetID"] as? String ?? name)
        } else {
            guard BackdropUserImages.isImage(url) else { return nil }
            let small = thumbnails.appendingPathComponent("\(name).heic")
            thumbnail = fileManager.fileExists(atPath: small.path) ? small : url
            isDynamic = false
            lightThumbnail = nil
            darkThumbnail = nil
            fullResolution = url
        }
    }

    /// `.thumbnails` of the Desktop Pictures folder holding `url` (a subfolder's pictures use it too).
    /// Read from the path's components, so a path with `..` (a hand-edited setting) ends.
    private static func thumbnailFolder(for url: URL) -> URL {
        let components = url.standardizedFileURL.pathComponents.dropLast()
        let folder = components.lastIndex(of: "Desktop Pictures").map { components[...$0] } ?? components[...]
        return URL(fileURLWithPath: NSString.path(withComponents: Array(folder)), isDirectory: true)
            .appendingPathComponent(".thumbnails", isDirectory: true)
    }
}

/// The full wallpaper pictures macOS has downloaded, by asset name (`<name>.heic` inside each
/// `*.asset/AssetData` folder of the desktop picture asset folders).
public nonisolated struct AppleWallpaperAssets: Sendable {
    /// Where macOS keeps downloaded desktop pictures.
    public static let systemFolders: [URL] = [
        URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture", isDirectory: true),
        URL(fileURLWithPath: "/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_DesktopPicture", isDirectory: true),
    ]

    /// No downloaded pictures (a picture file needs none).
    public static let none = AppleWallpaperAssets(files: [:])

    private let files: [String: URL]

    private init(files: [String: URL]) { self.files = files }

    /// Lists the downloaded pictures in `folders`.
    public init(folders: [URL] = Self.systemFolders, fileManager: FileManager = .default) {
        var files: [String: URL] = [:]
        for folder in folders {
            let assets = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for asset in assets where asset.pathExtension == "asset" {
                let data = asset.appendingPathComponent("AssetData", isDirectory: true)
                for file in (try? fileManager.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []
                where BackdropUserImages.isImage(file) {
                    let name = file.deletingPathExtension().lastPathComponent
                    files[name] = files[name] ?? file
                }
            }
        }
        self.files = files
    }

    /// The downloaded picture named `name`, if any.
    public func file(named name: String) -> URL? { files[name] }
}

/// Every wallpaper in the macOS Desktop Pictures folder, in the Wallpaper pane's order
/// (`.orderedPictures.plist`), then by name: the pictures and descriptions at its top, the
/// pictures in its folders (Solid Colors), and the still pictures of `.wallpapers`.
public nonisolated struct AppleWallpapers: Sendable {
    /// The picker collection they are listed under.
    public static let collection = "apple"

    /// The picker's title for them.
    public static var collectionTitle: String {
        String(localized: "backdrop.collection.apple", defaultValue: "Apple Wallpapers", bundle: .module)
    }

    /// The macOS wallpaper folder.
    public static let systemDirectory = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)

    public let wallpapers: [AppleWallpaper]

    /// Reads `directory`.
    ///
    /// - Parameters:
    ///   - directory: The Desktop Pictures folder.
    ///   - assets: The downloaded full pictures.
    ///   - fileManager: Lists the folder.
    public init(directory: URL = Self.systemDirectory, assets: AppleWallpaperAssets = AppleWallpaperAssets(),
                fileManager: FileManager = .default) {
        func list(_ folder: URL, hidden: Bool = false) -> [URL] {
            (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: hidden ? [] : [.skipsHiddenFiles])) ?? []
        }
        func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
        let top = list(directory)
        var files = top.filter { !isFolder($0) }
        for folder in top where isFolder(folder) { files += list(folder).filter { !isFolder($0) } }
        for folder in list(directory.appendingPathComponent(".wallpapers", isDirectory: true)) where isFolder(folder) {
            // A live wallpaper's folder also holds its movies and small thumbnails.
            files += list(folder).filter { ["heic", "heif"].contains($0.pathExtension.lowercased()) }
        }
        let order = (fileManager.contents(atPath: directory.appendingPathComponent(".orderedPictures.plist").path))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String] } ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        wallpapers = files.compactMap { AppleWallpaper(path: $0.path, assets: assets, fileManager: fileManager) }
            .sorted { a, b in
                let ra = rank[URL(fileURLWithPath: a.path).lastPathComponent] ?? Int.max
                let rb = rank[URL(fileURLWithPath: b.path).lastPathComponent] ?? Int.max
                if ra != rb { return ra < rb }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }
}
