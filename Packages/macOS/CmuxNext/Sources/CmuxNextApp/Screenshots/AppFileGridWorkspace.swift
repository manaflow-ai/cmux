import AppKit
import CmuxNextCompat
import CmuxNextFileGrid
import Foundation

/// How file grids open, reveal and trash files in the app: opens and
/// reveals run off the main thread (cx-050n, `NSWorkspace+Background`), so
/// a slow Launch Services lookup never stalls the window.
@MainActor
final class AppFileGridWorkspace: FileGridWorkspace {
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

    func recycle(_ urls: [URL]) async throws {
        _ = try await workspace.recycle(urls)
    }
}
