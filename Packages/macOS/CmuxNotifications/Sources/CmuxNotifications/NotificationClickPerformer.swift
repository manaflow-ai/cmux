import Foundation

/// Performs a notification's click action by deciding *what* to do and
/// delegating the AppKit/filesystem side effect to ``FinderRevealing``. Lifted
/// from `AppDelegate.performTerminalNotificationClickAction` and its private
/// `revealInFinder(path:)`: the tilde expansion, the empty-path guard, and the
/// file-then-containing-directory fallback all live here now; only the
/// `NSWorkspace`/`FileManager` primitives stay app-side behind the seam.
///
/// A `Service`-style helper (CONVENTIONS §2): it owns no state and performs one
/// capability through an injected seam. `@MainActor` because the original body
/// ran on the main actor and `NSWorkspace` is main-actor bound.
@MainActor
public final class NotificationClickPerformer: NotificationClickRouting {
    private let finder: any FinderRevealing

    /// Creates a click performer that routes filesystem side effects through
    /// the injected ``FinderRevealing`` seam.
    public init(finder: any FinderRevealing) {
        self.finder = finder
    }

    /// Performs `action`, returning whether it succeeded. Mirrors
    /// `performTerminalNotificationClickAction`.
    public func perform(_ action: NotificationNavClickAction) -> Bool {
        switch action {
        case .revealInFinder(let path):
            return revealInFinder(path: path)
        }
    }

    /// Reveals `path` in Finder: selects the file when it exists, else opens its
    /// containing directory, else fails. Mirrors `AppDelegate.revealInFinder(path:)`,
    /// including the tilde expansion and the empty-path guard.
    private func revealInFinder(path: String) -> Bool {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard !expandedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let fileURL = URL(fileURLWithPath: expandedPath)
        if finder.fileExists(atPath: fileURL.path) {
            return finder.selectFileInFinder(path: fileURL.path)
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        if finder.fileExists(atPath: directoryURL.path) {
            return finder.openDirectoryInFinder(path: directoryURL.path)
        }
        return false
    }
}
