public import AppKit

/// Opening a URL or revealing a file without the main thread waiting (cx-050n).
///
/// `NSWorkspace.open(_:)` and `activateFileViewerSelecting(_:)` make synchronous LaunchServices
/// and Finder calls. On a busy or slow system the main thread waited in
/// `_sandbox_extension_issue` long enough for the main-thread watchdog to fire
/// (`browser.downloads.showFolder` in the socket action sweep). These run the calls on a global
/// dispatch queue instead (not the cooperative pool, whose threads must not block). CmuxNext opens and reveals only through them
/// (scripts/cmux-next/check-concurrency.sh enforces it).
extension NSWorkspace {
    /// Opens `url` in its default app; `completion` runs on the main actor with whether it opened.
    public func openInBackground(_ url: URL, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            // The only sanctioned synchronous open (check-concurrency: workspace opens).
            let opened = NSWorkspace.shared.open(url)
            guard let completion else { return }
            // task-owner: one main-actor hop to report the open; nothing to cancel
            Task { @MainActor in completion(opened) }
        }
    }

    /// Opens `url` in its default app and brings that app to the front: for an open the person
    /// asked for (Sign In), where a page that appears behind cmux reads as a click that did
    /// nothing. Call it from the click, while cmux is active. The open is asynchronous (it never
    /// waits on LaunchServices), and cmux first yields activation to the handler so
    /// cooperative activation lets it come forward. Returns false when no app opens `url`.
    @MainActor @discardableResult
    public func openInForeground(_ url: URL) -> Bool {
        guard let app = urlForApplication(toOpen: url) else { return false }
        if let bundleID = Bundle(url: app)?.bundleIdentifier {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        open([url], withApplicationAt: app, configuration: configuration)
        return true
    }

    /// Selects `urls` in a Finder window.
    public func revealInBackground(_ urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}
