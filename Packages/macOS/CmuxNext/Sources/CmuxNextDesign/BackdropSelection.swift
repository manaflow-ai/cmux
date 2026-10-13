public import AppKit
public import Foundation

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
        switch self {
        case .art(let art): return art.label
        case .system(let path), .file(let path): return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case .desktop: return String(localized: "backdrop.desktop.title", defaultValue: "Desktop Wallpaper", bundle: .module)
        }
    }

    /// The attribution shown below the thumbnail.
    public var attribution: String {
        switch self {
        case .art(let art): return art.attribution
        case .system(let path):
            return String(localized: "backdrop.system.attribution", defaultValue: "macOS system wallpaper · %@", bundle: .module)
                .replacingOccurrences(of: "%@", with: URL(fileURLWithPath: path).lastPathComponent)
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

    /// The tint the selected work looks best under, replacing the theme's; nil for other sources.
    public var preferredTintOpacity: Double? {
        if case .art(let art) = self { return art.metadata.preferredTintOpacity }
        return nil
    }

    /// The selected work's measured darkest and lightest colors; nil when unknown.
    public var artRange: BackdropArtRange? {
        if case .art(let art) = self { return art.metadata.range }
        return nil
    }

    /// A small image of the selection that is always here: the bundled thumbnail for art.
    public var thumbnailURL: URL? {
        if case .art(let art) = self { return art.thumbnailURL }
        return imageURL
    }

    /// The least theme tint over this image at full opacity (``BackdropArtMetadata/minimumTintOpacity``).
    public var minimumTintOpacity: Double {
        if case .art(let art) = self { return art.metadata.minimumTintOpacity }
        return 0
    }

    /// Loads the selected image on the main actor for AppKit rendering.
    @MainActor public func image() -> NSImage? {
        resolvedImageURL().flatMap(NSImage.init(contentsOf:))
    }

    /// The selected image file; nil for ``desktop``, which only the main actor can resolve.
    public var imageURL: URL? {
        switch self {
        case .art(let art): return art.imageURL
        case .system(let path), .file(let path): return URL(fileURLWithPath: path)
        case .desktop: return nil
        }
    }

    /// The selected image file, reading the desktop picture of the main screen for ``desktop``.
    @MainActor public func resolvedImageURL() -> URL? {
        guard case .desktop = self else { return imageURL }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
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
