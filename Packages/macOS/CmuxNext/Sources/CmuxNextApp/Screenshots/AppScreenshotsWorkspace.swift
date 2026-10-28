import AppKit
import CmuxNextCompatAppKit
import CmuxNextScreenshots
import Foundation

/// How the Screenshots pane opens and reveals files in the app: opens and
/// reveals run off the main thread (cx-050n, `NSWorkspace+Background`), so
/// a slow Launch Services lookup never stalls the window.
@MainActor
final class AppScreenshotsWorkspace: ScreenshotsWorkspace {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func open(_ urls: [URL]) {
        for url in urls { workspace.openInBackground(url) }
    }

    func reveal(_ urls: [URL]) {
        workspace.revealInBackground(urls)
    }
}
