import Foundation

/// The reveal-in-Finder seam: the package decides *what* to reveal (the path,
/// after tilde-expansion and the file-vs-directory fallback) and the app target
/// performs the `NSWorkspace` side effect. Splitting it this way lets the
/// click-action router live in the package while the only AppKit dependency
/// (`NSWorkspace`) stays app-side.
///
/// `selectFileInFinder` mirrors `NSWorkspace.shared.activateFileViewerSelecting`
/// for a single URL; `openDirectoryInFinder` mirrors `NSWorkspace.shared.open`.
/// `fileExists` mirrors `FileManager.default.fileExists(atPath:)`. Each returns
/// the same `Bool` the legacy `NSWorkspace`/`FileManager` call returned.
@MainActor
public protocol FinderRevealing: AnyObject {
    /// Whether a file or directory exists at `path`. Mirrors
    /// `FileManager.default.fileExists(atPath:)`.
    func fileExists(atPath path: String) -> Bool

    /// Reveals and selects the file at `path` in Finder. Mirrors
    /// `NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:)])`,
    /// which returns no status, so this returns `true` to match the legacy body.
    @discardableResult
    func selectFileInFinder(path: String) -> Bool

    /// Opens the directory at `path` in Finder, returning whether it opened.
    /// Mirrors `NSWorkspace.shared.open(URL(fileURLWithPath:))`.
    func openDirectoryInFinder(path: String) -> Bool
}
