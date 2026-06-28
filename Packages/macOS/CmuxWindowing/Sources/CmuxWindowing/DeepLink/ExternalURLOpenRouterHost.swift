public import Foundation

/// App-target seam for the live work the ``ExternalURLOpenRouter`` orchestrates
/// for `NSApplicationDelegate.application(_:open:)` but cannot own.
///
/// The router sequences the deep-link open flow (cmux-scheme routes first, then
/// auth callbacks, then the partitioned terminal/file-preview/directory opens),
/// but every step that touches live app state stays on the `@main` app
/// delegate: the cmux-scheme external-route handler, the auth callback graph
/// (`auth?.callbackRouter`/`auth?.browserSignIn`), the external-open URL
/// classifier, the startup open-intent latch, and the three window/workspace
/// open effects. The app delegate conforms and injects itself as the host so
/// the pure orchestration lives in this package while these app-only effects
/// stay app-side. The DEBUG `AuthDebugLog` diagnostics and all localized
/// strings stay app-side too and never reach this seam.
@MainActor
public protocol ExternalURLOpenRouterHost: AnyObject {
    /// Handles the app's own cmux-scheme external routes (and emits the DEBUG
    /// received/handled diagnostics) for `urls`.
    ///
    /// - Returns: `true` when the URLs were consumed by an external route, in
    ///   which case the router stops without classifying or opening anything.
    func handleExternalRoutes(_ urls: [URL]) -> Bool

    /// Routes any auth-callback URLs in `urls` through the auth graph, signing
    /// in via the browser sign-in flow when configured.
    func handleAuthCallbacks(_ urls: [URL])

    /// The non-directory file URLs to open, classified from `urls` (directories
    /// and the running app bundle already excluded), in input order.
    func classifiedFileURLs(from urls: [URL]) -> [URL]

    /// The ordered, de-duplicated directories to open as workspaces, classified
    /// from `urls`.
    func classifiedDirectories(from urls: [URL]) -> [String]

    /// Latches that an explicit external open intent happened at startup, so a
    /// pending session restore is suppressed.
    func prepareForExplicitOpenIntentAtStartup()

    /// Opens `request` in a terminal (preferred main window, falling back to a
    /// new main window), tagging the debug trail with `debugSource`.
    func openTerminalDefaultFileRequest(
        _ request: TerminalDefaultFileOpenRequest,
        debugSource: String
    )

    /// Opens a file preview for `filePath` in the preferred main window,
    /// tagging the debug trail with `debugSource`.
    func openFilePreview(filePath: String, debugSource: String)

    /// Opens a workspace for `directory` in the preferred main window (creating
    /// one when none is available), tagging the debug trail with `debugSource`.
    func openWorkspaceForExternalDirectory(_ directory: String, debugSource: String)
}
