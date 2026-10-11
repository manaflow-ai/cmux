public import AppKit

/// Opening a URL or revealing a file without the main thread waiting (cx-050n).
///
/// `NSWorkspace.open(_:)` and `activateFileViewerSelecting(_:)` make synchronous LaunchServices
/// and Finder calls. On a busy or slow system the main thread waited in
/// `_sandbox_extension_issue` long enough for the main-thread watchdog to fire
/// (`browser.downloads.showFolder` in the socket action sweep). These run the calls from a
/// detached task instead. CmuxNext opens and reveals only through them
/// (scripts/cmux-next/check-concurrency.sh enforces it).
extension NSWorkspace {
    /// Opens `url` in its default app; `completion` runs on the main actor with whether it opened.
    public func openInBackground(_ url: URL, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        // task-owner: one LaunchServices open; ends when it returns, nothing to cancel
        Task.detached(priority: .userInitiated) {
            // The only sanctioned synchronous open (check-concurrency: workspace opens).
            let opened = NSWorkspace.shared.open(url)
            if let completion { await completion(opened) }
        }
    }

    /// Selects `urls` in a Finder window.
    public func revealInBackground(_ urls: [URL]) {
        // task-owner: one Finder request; ends when it returns, nothing to cancel
        Task.detached(priority: .userInitiated) {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}
