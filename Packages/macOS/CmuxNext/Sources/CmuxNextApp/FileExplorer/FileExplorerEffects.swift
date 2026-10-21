import Foundation

/// What the file explorer's actions do outside the explorer: open in cmux or
/// another app, reveal in Finder, copy text. ``AppFileExplorerEffects`` in the
/// App, a recorder in tests.
@MainActor
protocol FileExplorerEffects: AnyObject {
    /// Opens `file` in cmux beside the focused pane; false when cmux shows no viewer for its kind.
    func openInCmux(_ file: URL) -> Bool
    /// Opens `item` in its default app (a folder in Finder).
    func openInDefaultApp(_ item: URL)
    /// Selects `item` in a Finder window.
    func revealInFinder(_ item: URL)
    /// Puts `text` on the general pasteboard.
    func copy(_ text: String)
    /// Opens `item` with the app named by `app` (a bundle id, an app path or an app name).
    func open(_ item: URL, withApp app: String) async throws
}
