import CmuxNextCompat
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
    public init?(path: String, assets: AppleWallpaperAssets) {
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        let thumbnails = Self.thumbnailFolder(for: url)
        func variant(_ base: URL, _ suffix: String) -> URL? {
            let file = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.deletingPathExtension().lastPathComponent) \(suffix).\(base.pathExtension)")
            return FileManager.checked.fileExists(atPath: file.path) ? file : nil
        }
        self.path = path
        title = name
        if url.pathExtension.lowercased() == "madesktop" {
            guard let data = FileManager.checked.contents(atPath: path),
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
            thumbnail = FileManager.checked.fileExists(atPath: small.path) ? small : url
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
    public init(folders: [URL] = Self.systemFolders) {
        var files: [String: URL] = [:]
        for folder in folders {
            let assets = (try? FileManager.checked.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for asset in assets where asset.pathExtension == "asset" {
                let data = asset.appendingPathComponent("AssetData", isDirectory: true)
                for file in (try? FileManager.checked.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []
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

    /// The system folders' pictures, listed again once the last list is a few seconds old: a
    /// window reads its wallpaper several times per change and the picker once per tile, while a
    /// download in System Settings shows up soon after.
    public static func recent(now: Date = Date()) -> AppleWallpaperAssets {
        recent(now: now) { AppleWallpaperAssets() }
    }

    /// ``recent(now:)`` with the folder listing passed in. The listing runs with the lock free: the
    /// lock covers only the kept list, so a reader never waits for another's directory walk (two
    /// readers of a stale list may both list; the later one is kept).
    static func recent(now: Date, listing: () -> AppleWallpaperAssets) -> AppleWallpaperAssets {
        let kept = recentList.withLock { last -> AppleWallpaperAssets? in
            guard let last, now.timeIntervalSince(last.listed) < 5, now >= last.listed else { return nil }
            return last.assets
        }
        if let kept { return kept }
        let assets = listing()
        recentList.withLock { $0 = (now, assets) }
        return assets
    }

    private static let recentList = Mutex<(listed: Date, assets: AppleWallpaperAssets)?>(nil)
}
