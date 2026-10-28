public import AppKit
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Opening a URL or revealing a file without the main thread waiting (cx-050n).
///
/// `NSWorkspace.open(_:)` and `activateFileViewerSelecting(_:)` make synchronous LaunchServices
/// and Finder calls. On a busy or slow system the main thread waited in
/// `_sandbox_extension_issue` long enough for the main-thread watchdog to fire
/// (`browser.downloads.showFolder` in the socket action sweep). These run the calls on a named concurrent
/// queue, `com.cmuxterm.next.workspace-open`, instead (not the cooperative pool, whose threads must not block,
/// and not a root queue, which has no name).
/// CmuxNext opens and reveals only through them
/// (scripts/cmux-next/check-concurrency.sh enforces it). Every `open` form goes through here, the
/// completion-handler ones too, so no caller depends on how much of an open LaunchServices does
/// before it returns. Each call uses the workspace it is called on, so an injected one is honored.
extension NSWorkspace {
    /// Opens `url` in its default app; `completion` runs on the main actor with whether it opened.
    public func openInBackground(_ url: URL, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        inBackground { workspace in
            // The only sanctioned synchronous open (check-concurrency: workspace opens).
            // concurrency-allow: inBackground runs this body on the named workspace-open queue, never on the main thread.
            let opened = workspace.open(url)
            guard let completion else { return }
            // task-owner: one main-actor hop to report the open; nothing to cancel
            // main-hop-allow: Compat sits below CmuxNextWakeups and has no class to post in; one report per open the caller asked for
            Task { @MainActor in completion(opened) }
        }
    }

    /// Opens `urls` with the app at `app`, bringing it to the front.
    public func openInBackground(_ urls: [URL], withApplicationAt app: URL) {
        inBackground { workspace in
            // concurrency-allow: inBackground runs this body on the named workspace-open queue, never on the main thread.
            workspace.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Opens `urls` with the app at `app`, bringing it to the front, and returns whether it opened (false when
    /// the open's completion was dropped without an answer).
    public func openedInBackground(_ urls: [URL], withApplicationAt app: URL) async -> Bool {
        (try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
            inBackground { workspace in
                // concurrency-allow: inBackground runs this body on the named workspace-open queue, never on the main thread.
                workspace.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }) ?? false
    }

    /// Selects `urls` in a Finder window.
    public func revealInBackground(_ urls: [URL]) {
        inBackground { workspace in
            // concurrency-allow: inBackground runs this body on the named workspace-open queue, never on the main thread.
            workspace.activateFileViewerSelecting(urls)
        }
    }

    /// Runs one open or reveal on this workspace, off the caller's thread.
    private func inBackground(_ body: @escaping @Sendable (NSWorkspace) -> Void) {
        // crash-allow: the queue only calls this workspace's open and reveal methods, the calls these helpers always made off main on NSWorkspace.shared; it reads and writes no other state of it
        nonisolated(unsafe) let workspace = self
        // Concurrent, so one slow LaunchServices call never holds the next, and it targets GCD's width-limited root
        // queue (a serial queue targets the overcommit one, a new thread per blocked call): a scripted burst of
        // opens parks no more threads than the unnamed root queue did. A person waits for the app or Finder window.
        DispatchQueue(label: "com.cmuxterm.next.workspace-open", qos: .userInitiated, attributes: .concurrent)
            .async { body(workspace) }
    }
}
