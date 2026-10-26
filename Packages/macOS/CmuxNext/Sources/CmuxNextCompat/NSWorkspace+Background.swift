public import AppKit

/// Opening a URL or revealing a file without the main thread waiting (cx-050n).
///
/// `NSWorkspace.open(_:)` and `activateFileViewerSelecting(_:)` make synchronous LaunchServices
/// and Finder calls. On a busy or slow system the main thread waited in
/// `_sandbox_extension_issue` long enough for the main-thread watchdog to fire
/// (`browser.downloads.showFolder` in the socket action sweep). These run the calls on a global
/// dispatch queue instead (not the cooperative pool, whose threads must not block). CmuxNext opens and reveals only through them
/// (scripts/cmux-next/check-concurrency.sh enforces it). Every `open` form goes through here, the
/// completion-handler ones too, so no caller depends on how much of an open LaunchServices does
/// before it returns.
extension NSWorkspace {
    /// Opens `url` in its default app; `completion` runs on the main actor with whether it opened.
    public func openInBackground(_ url: URL, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        Self.inBackground {
            // The only sanctioned synchronous open (check-concurrency: workspace opens).
            let opened = NSWorkspace.shared.open(url)
            guard let completion else { return }
            // task-owner: one main-actor hop to report the open; nothing to cancel
            Task { @MainActor in completion(opened) }
        }
    }

    /// Opens `urls` with the app at `app`, bringing it to the front.
    public func openInBackground(_ urls: [URL], withApplicationAt app: URL) {
        Self.inBackground {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Opens `urls` with the app at `app`, bringing it to the front, and returns whether it opened.
    public func openedInBackground(_ urls: [URL], withApplicationAt app: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            Self.inBackground {
                NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }
    }

    /// Selects `urls` in a Finder window.
    public func revealInBackground(_ urls: [URL]) {
        Self.inBackground {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// Runs one open or reveal off the caller's thread.
    private static func inBackground(_ body: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: body)
    }
}
