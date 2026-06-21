import AppKit
import Foundation

/// The production ``FinderRevealing`` conformer: performs the reveal-in-Finder
/// side effects through `FileManager.default` and `NSWorkspace.shared`. Lifted
/// byte-identically from the former `AppDelegate` `finderFileExists` /
/// `finderSelectFile` / `finderOpenDirectory` helpers, which reached only these
/// process-wide system globals and never any `AppDelegate` state, so the seam's
/// app-side split was unnecessary for the production path. The protocol remains
/// so tests can inject a fake; production constructs this concrete at the
/// composition root and injects it as `any FinderRevealing` (CONVENTIONS §3).
///
/// `@MainActor` because `NSWorkspace` is main-actor bound, matching the original
/// helpers' main-actor isolation.
@MainActor
public final class SystemFinderRevealer: FinderRevealing {
    /// Creates a Finder revealer over the shared `FileManager`/`NSWorkspace`.
    public init() {}

    /// Whether a file or directory exists at `path`. Mirrors
    /// `FileManager.default.fileExists(atPath:)`.
    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Reveals and selects the file at `path` in Finder, returning `true`.
    /// Mirrors `NSWorkspace.shared.activateFileViewerSelecting([URL(...)])`,
    /// which returns no status, so the legacy helper returned `true` here.
    @discardableResult
    public func selectFileInFinder(path: String) -> Bool {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return true
    }

    /// Opens the directory at `path` in Finder, returning whether it opened.
    /// Mirrors `NSWorkspace.shared.open(URL(fileURLWithPath:))`.
    public func openDirectoryInFinder(path: String) -> Bool {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
