import Foundation

/// Shared action backing the session-index row "Open Working Directory" menu
/// item (used by both the full row and the popover row). The menu item is only
/// surfaced when the row has a working directory (like its sibling items, which
/// hide when their data is absent), so this takes a non-optional path and routes
/// it through the shared Finder opener — existence check, reveal, and beep on a
/// stale/moved directory. `open` defaults to that opener; tests inject a
/// capturing closure to observe the routed URL. See issue #5977.
enum SessionRowDirectoryOpener {
    @MainActor
    static func openWorkingDirectory(
        cwd: String,
        open: @MainActor (URL) async -> Void = { await WorkspaceFinderDirectoryOpener.openInFinder($0) }
    ) async {
        await open(URL(fileURLWithPath: cwd))
    }
}

@MainActor
struct SessionRowMenuActions {
    var openWorkingDirectoryURL: @MainActor (URL) async -> Void

    static let live = SessionRowMenuActions { url in
        await WorkspaceFinderDirectoryOpener.openInFinder(url)
    }

    func openWorkingDirectory(for entry: SessionEntry) async {
        guard let cwd = entry.cwd, !cwd.isEmpty else { return }
        await SessionRowDirectoryOpener.openWorkingDirectory(cwd: cwd, open: openWorkingDirectoryURL)
    }
}
