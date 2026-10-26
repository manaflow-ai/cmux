public import AppKit
public import Foundation
import os
import ImageIO

/// A selectable image source for the window backdrop. Each case is one source: the bundled art,
/// a macOS wallpaper file, the person's own image, or their current desktop picture. Each has its
/// own id prefix and resolves through ``resolvedImageURL()``.
public nonisolated enum BackdropSelection: Equatable, Hashable, Sendable {
    /// Art packaged with cmux.
    case art(BackdropArt)
    /// A wallpaper supplied by macOS at an absolute path.
    case system(path: String)
    /// The person's own image in the backgrounds folder (``BackdropUserImages``), at an absolute path.
    case file(path: String)
    /// The main screen's current desktop picture, read when a window loads its backdrop. Only
    /// shown when chosen; never the default.
    case desktop

    /// The persisted id of ``desktop``.
    public static let desktopID = "desktop"

    /// A stable value suitable for `cmux.json`.
    public var id: String {
        switch self {
        case .art(let art): return art.rawValue
        case .system(let path): return "system:\(path)"
        case .file(let path): return "file:\(path)"
        case .desktop: return Self.desktopID
        }
    }

    /// The short title shown in the wallpaper grid: "Title — Artist" for art.
    public var title: String {
        title(aerialNames: nil)
    }

    /// The title using metadata retained by the catalog, without rereading the aerial file.
    public func title(aerialNames: [String: String]?) -> String {
        switch self {
        case .art(let art): return art.label
        case .system(let path): return Self.systemTitle(path, aerialNames: aerialNames)
        case .file(let path): return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case .desktop: return String(localized: "backdrop.desktop.title", defaultValue: "Desktop Wallpaper", bundle: .module)
        }
    }

    /// A macOS wallpaper's name: a shipped video's without its cut, an aerial's from idleassetsd.
    private static func systemTitle(_ path: String, aerialNames: [String: String]? = nil) -> String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard AppleWallpapers.isVideo(path) else { return name }
        if let aerial = (aerialNames ?? AppleWallpapers.system.aerialNames())[name] { return aerial }
        return [" Light", " Dark", " Landscape"].reduce(name) { $0.replacingOccurrences(of: $1, with: "") }
    }

    /// Whether the window plays this choice as a looping video (a shipped wallpaper, an aerial,
    /// or the person's own movie); its first frame stands in while paused.
    public var isVideo: Bool {
        switch self {
        case .system(let path), .file(let path): return AppleWallpapers.isVideo(path)
        case .art, .desktop: return false
        }
    }

    /// The picker group: the art's collection, the person's own images, Apple Wallpapers for a
    /// macOS still, or Moving wallpapers for every video (Apple's, downloaded aerials, the
    /// person's own); nil for the untitled group (the desktop picture).
    public var pickerCollection: (id: String, title: String)? {
        switch self {
        case .art(let art): return (art.collection.rawValue, art.collection.title)
        case .file: return isVideo ? Self.videoCollection : (BackdropUserImages.collection, BackdropUserImages.collectionTitle)
        case .system: return isVideo ? Self.videoCollection : (AppleWallpapers.collection, AppleWallpapers.collectionTitle)
        case .desktop: return nil
        }
    }

    private static var videoCollection: (String, String) {
        (AppleWallpapers.videoCollection, String(localized: "backdrop.collection.video", defaultValue: "Moving wallpapers", bundle: .module))
    }

    /// The attribution shown below the thumbnail.
    public var attribution: String {
        attribution(title: title)
    }

    /// The attribution using a title the caller already resolved.
    public func attribution(title: String) -> String {
        switch self {
        case .art(let art): return art.attribution
        case .system:
            return String(localized: "backdrop.system.attribution", defaultValue: "macOS system wallpaper · %@", bundle: .module)
                .replacingOccurrences(of: "%@", with: title)
        case .file(let path):
            return String(localized: "backdrop.file.attribution", defaultValue: "Your image · %@", bundle: .module)
                .replacingOccurrences(of: "%@", with: URL(fileURLWithPath: path).lastPathComponent)
        case .desktop:
            return String(localized: "backdrop.desktop.attribution", defaultValue: "Your current macOS desktop picture", bundle: .module)
        }
    }

    /// The museum source for bundled art, or nil for a local file.
    public var sourceURL: URL? {
        switch self {
        case .art(let art): return art.sourceURL
        case .system, .file, .desktop: return nil
        }
    }

    /// A small image of the selection that is always here: the bundled thumbnail for art, the
    /// Desktop Pictures thumbnail for a macOS wallpaper.
    public var thumbnailURL: URL? {
        switch self {
        case .art(let art): return art.thumbnailURL
        case .system(let path): return appleWallpaper(path, downloads: false).map(\.thumbnail) ?? imageURL
        case .file, .desktop: return imageURL
        }
    }

    /// Loads the selected image on the main actor for AppKit rendering.
    @MainActor public func image() -> NSImage? {
        resolvedImageURL().flatMap(NSImage.init(contentsOf:))
    }

    /// The selected image file in the light appearance; nil for ``desktop``, which only the main
    /// actor can resolve.
    public var imageURL: URL? { imageURL(for: .light) }

    /// The selected image file for `appearance`. A macOS wallpaper that is not downloaded yet is
    /// its thumbnail (for that appearance when it is dynamic) until the person downloads it.
    public func imageURL(for appearance: BackdropAppearance) -> URL? {
        switch self {
        case .art(let art): return art.imageURL
        case .system(let path):
            if AppleWallpapers.isVideo(path) { return AppleWallpapers.file(for: path, dark: appearance == .dark) }
            return appleWallpaper(path)?.imageURL(for: appearance) ?? URL(fileURLWithPath: path)
        case .file(let path): return URL(fileURLWithPath: path)
        case .desktop: return nil
        }
    }

    /// Whether the window draws another file or frame in light and dark: Apple's moving
    /// wallpaper's cuts, a dynamic macOS wallpaper (downloaded or not), or a picture with a frame
    /// for each appearance. Read once per path (the cache keys images by it).
    public var followsAppearance: Bool {
        guard case .system(let path) = self else { return false }
        if AppleWallpapers.isVideo(path) { return AppleWallpapers.hasCuts(path) }
        if let known = Self.follows.withLock({ $0[path] }) { return known }
        let follows: Bool
        if let wallpaper = appleWallpaper(path), wallpaper.isDynamic {
            follows = true
        } else if let url = imageURL(for: .light), let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            follows = BackdropAppearance.light.frame(in: source) != BackdropAppearance.dark.frame(in: source)
        } else {
            follows = false
        }
        Self.follows.withLock { $0[path] = follows }
        return follows
    }

    private static let follows = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    /// The selected image file, reading the desktop picture of the main screen for ``desktop``.
    /// Apple's moving wallpaper resolves to its cut, and a dynamic macOS wallpaper to its picture,
    /// for the app's light or dark appearance.
    @MainActor public func resolvedImageURL() -> URL? {
        resolvedImageURL(dark: NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    /// The selected file in light or dark: Apple's moving wallpaper's cut, or a macOS wallpaper's
    /// picture (its thumbnail until downloaded), for the appearance.
    @MainActor public func resolvedImageURL(dark: Bool) -> URL? {
        switch self {
        case .system: return imageURL(for: dark ? .dark : .light)
        case .desktop:
            // macOS can report a file that is gone, a folder or a wallpaper description; resolve
            // it to a picture that decodes (the fill color when there is none).
            return DesktopPicture(screen: NSScreen.main ?? NSScreen.screens.first).resolvedURL(dark: dark)
        case .art, .file: return imageURL
        }
    }

    /// The image cache's key: the id, and for a choice that follows the appearance, which one.
    public func variantID(dark: Bool) -> String {
        followsAppearance ? "\(id)|\(dark ? "dark" : "light")" : id
    }

    /// The macOS wallpaper a `.madesktop` description names (other system files are pictures).
    /// `downloads` looks for its full picture; a thumbnail needs none.
    private func appleWallpaper(_ path: String, downloads: Bool = true) -> AppleWallpaper? {
        guard path.lowercased().hasSuffix(".madesktop") || path.contains("/Desktop Pictures/") else { return nil }
        let described = downloads && path.lowercased().hasSuffix(".madesktop")
        return AppleWallpaper(path: path, assets: described ? .recent() : .none)
    }

    /// Decodes a persisted selection, accepting the legacy `backdropArt` value.
    public init?(id: String) {
        if let art = BackdropArt(id: id) {
            self = .art(art)
        } else if id == Self.desktopID {
            self = .desktop
        } else if id.hasPrefix("system:") {
            let path = String(id.dropFirst("system:".count))
            guard path.hasPrefix("/"), !path.isEmpty else { return nil }
            self = .system(path: path)
        } else if id.hasPrefix("file:") {
            let path = String(id.dropFirst("file:".count))
            guard path.hasPrefix("/") else { return nil }
            self = .file(path: path)
        } else {
            return nil
        }
    }
}
