public import AppKit
public import CmuxNextAppearance
import CmuxNextCompat
public import Foundation
import ImageIO

/// A backdrop choice resolved to what the window draws: its files and thumbnail for light and dark
/// (macOS wallpapers, the desktop picture, the bundled images) and its image.
nonisolated extension BackdropSelection {
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
        } else if let url = imageURL(for: .light), let source = CheckedImageSource(blockingContentsOf: url)?.source {
            follows = BackdropAppearance.light.frame(in: source) != BackdropAppearance.dark.frame(in: source)
        } else {
            follows = false
        }
        Self.follows.withLock { $0[path] = follows }
        return follows
    }

    private static let follows = Mutex<[String: Bool]>([:])

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
}
