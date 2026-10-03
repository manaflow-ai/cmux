public import AppKit
public import Foundation

/// A selectable image source for the window backdrop.
public nonisolated enum BackdropSelection: Equatable, Hashable, Sendable {
    /// A painting packaged with cmux.
    case art(BackdropArt)
    /// A wallpaper supplied by macOS at an absolute path.
    case system(path: String)

    /// A stable value suitable for `cmux.json`.
    public var id: String {
        switch self {
        case .art(let art): return art.rawValue
        case .system(let path): return "system:\(path)"
        }
    }

    /// The short title shown in the wallpaper grid.
    public var title: String {
        switch self {
        case .art(let art): return art.title
        case .system(let path): return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }

    /// The attribution shown below the thumbnail.
    public var attribution: String {
        switch self {
        case .art(let art): return art.attribution
        case .system(let path):
            return String(localized: "backdrop.system.attribution", defaultValue: "macOS system wallpaper · %@", bundle: .module)
                .replacingOccurrences(of: "%@", with: URL(fileURLWithPath: path).lastPathComponent)
        }
    }

    /// The museum source for bundled art, or nil for a local system wallpaper.
    public var sourceURL: URL? {
        switch self {
        case .art(let art): return art.sourceURL
        case .system: return nil
        }
    }

    /// Loads the selected image on the main actor for AppKit rendering.
    @MainActor public func image() -> NSImage? {
        switch self {
        case .art(let art): return art.image()
        case .system(let path): return NSImage(contentsOf: URL(fileURLWithPath: path))
        }
    }

    /// Decodes a persisted selection, accepting the legacy `backdropArt` value.
    public init?(id: String) {
        if let art = BackdropArt(rawValue: id) {
            self = .art(art)
        } else if id.hasPrefix("system:") {
            let path = String(id.dropFirst("system:".count))
            guard path.hasPrefix("/"), !path.isEmpty else { return nil }
            self = .system(path: path)
        } else {
            return nil
        }
    }
}
