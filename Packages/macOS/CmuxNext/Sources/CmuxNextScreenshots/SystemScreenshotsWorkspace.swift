public import AppKit
import CmuxNextCompat
import Foundation

/// How the Screenshots pane opens and reveals files in the app: opens and
/// reveals run off the main thread (cx-050n, `NSWorkspace+Background`), so
/// a slow Launch Services lookup never stalls the window.
@MainActor
public final class SystemScreenshotsWorkspace: ScreenshotsWorkspace {
    private let workspace: NSWorkspace

    /// Makes the adapter.
    ///
    /// - Parameter workspace: the system workspace (default: `.shared`).
    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func open(_ urls: [URL]) {
        for url in urls { workspace.openInBackground(url) }
    }

    public func reveal(_ urls: [URL]) {
        workspace.revealInBackground(urls)
    }
}
