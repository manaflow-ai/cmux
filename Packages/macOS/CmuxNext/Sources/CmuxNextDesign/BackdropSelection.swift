public import AppKit
public import Foundation

/// A selectable image source for the window backdrop. Each case is one source: the bundled art,
/// a macOS wallpaper file, or the user's current desktop picture. A downloaded pack would be one
/// more case with its own id prefix, resolved the same way through ``resolvedImageURL()``.
public nonisolated enum BackdropSelection: Equatable, Hashable, Sendable {
    /// Art packaged with cmux.
    case art(BackdropArt)
    /// A wallpaper supplied by macOS at an absolute path.
    case system(path: String)
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
        case .desktop: return Self.desktopID
        }
    }

    /// The short title shown in the wallpaper grid.
    public var title: String {
        switch self {
        case .art(let art): return art.title
        case .system(let path): return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
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
        case .desktop:
            return String(localized: "backdrop.desktop.attribution", defaultValue: "Your current macOS desktop picture", bundle: .module)
        }
    }

    /// The museum source for bundled art, or nil for a local system wallpaper.
    public var sourceURL: URL? {
        switch self {
        case .art(let art): return art.sourceURL
        case .system, .desktop: return nil
        }
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
        case .system(let path): return URL(fileURLWithPath: path)
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
        if let art = BackdropArt(rawValue: id) {
            self = .art(art)
        } else if id == Self.desktopID {
            self = .desktop
        } else if id.hasPrefix("system:") {
            let path = String(id.dropFirst("system:".count))
            guard path.hasPrefix("/"), !path.isEmpty else { return nil }
            self = .system(path: path)
        } else {
            return nil
        }
    }
}
