/// App-target seam for the three window/workspace effects the
/// ``ExternalOpenIntentCoordinator`` drives but cannot own.
///
/// They live on the `@main` app delegate (window + tab-manager construction,
/// preferred-main-window routing, and the startup open-intent latch that
/// suppresses a pending session restore). The app delegate conforms and
/// injects itself as the host so the pure decision/loop layer stays in this
/// package while these app-only effects stay app-side. The localized
/// "no folder path" error string and the `NSPasteboard` reading stay app-side
/// too and never reach this seam.
@MainActor
public protocol ExternalOpenIntentHosting: AnyObject {
    /// Latches that an explicit external open intent happened at startup, so a
    /// pending session restore is suppressed.
    func prepareForExplicitOpenIntentAtStartup()

    /// Creates a new main window seeded with `workingDirectory`.
    func createMainWindowForExternalOpen(workingDirectory: String)

    /// Adds a workspace seeded with `workingDirectory` in the preferred main
    /// window, bringing it to the front.
    ///
    /// - Returns: `true` when a preferred main window existed and the workspace
    ///   was added; `false` when none was available, in which case the caller
    ///   falls back to creating a new main window.
    func addWorkspaceInPreferredMainWindowForExternalOpen(
        workingDirectory: String,
        debugSource: String
    ) -> Bool
}
