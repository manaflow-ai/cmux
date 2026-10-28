public import Foundation

/// What the picker and Settings show for a backdrop choice: its title, its credit, its source and
/// its picker group.
nonisolated extension BackdropSelection {
    /// The short title shown in the wallpaper grid: "Title — Artist" for art.
    public var title: String {
        switch self {
        case .art(let art): return art.label
        case .system(let path): return Self.systemTitle(path)
        case .file(let path): return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case .desktop: return String(localized: "backdrop.desktop.title", defaultValue: "Desktop Wallpaper", bundle: .module)
        }
    }

    /// A macOS wallpaper's name: a shipped video's without its cut, an aerial's from idleassetsd.
    private static func systemTitle(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard AppleWallpapers.isVideo(path) else { return name }
        if let aerial = AppleWallpapers.system.aerialNames()[name] { return aerial }
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
        switch self {
        case .art(let art): return art.attribution
        case .system(let path):
            return String(localized: "backdrop.system.attribution", defaultValue: "macOS system wallpaper · %@", bundle: .module)
                .replacingOccurrences(of: "%@", with: Self.systemTitle(path))
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
}
