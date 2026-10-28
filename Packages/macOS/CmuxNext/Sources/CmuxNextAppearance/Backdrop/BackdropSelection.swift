public import Foundation

/// A selectable image source for the window backdrop. Each case is one source: the bundled art,
/// a macOS wallpaper file, the person's own image, or their current desktop picture. Each has its
/// own id prefix and resolves through `resolvedImageURL()` (CmuxNextDesign).
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
