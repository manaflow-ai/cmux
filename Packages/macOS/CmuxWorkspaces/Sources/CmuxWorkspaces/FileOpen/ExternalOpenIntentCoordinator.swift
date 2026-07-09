/// Maps each directory resolved from an external open intent to a concrete
/// window-vs-workspace open.
///
/// The pasteboard / URL / error-string layer stays in the app target (it
/// touches `NSPasteboard`, the app-owned service resolvers, and the localized
/// error string), and the pure URL→directories classification already lives in
/// ``ExternalOpenURLClassifier``. This coordinator owns only the residual
/// decision/loop the app delegate used to inline: latch the startup
/// open-intent, then for each directory either open a new main window or add a
/// workspace in the preferred main window (falling back to a new window).
///
/// It owns no state; every window/workspace effect is delegated to the
/// app-target ``ExternalOpenIntentHosting`` injected at construction.
@MainActor
public final class ExternalOpenIntentCoordinator {
    private let host: any ExternalOpenIntentHosting

    /// Creates a coordinator that drives `host` for each open effect.
    public init(host: any ExternalOpenIntentHosting) {
        self.host = host
    }

    /// Opens every directory in `directories` against `target`, after latching
    /// the startup open-intent so a pending session restore is suppressed.
    ///
    /// Callers resolve and de-duplicate `directories` (and report the empty
    /// case) before calling this; the latch fires only when there is at least
    /// one directory to open, matching the legacy ordering.
    public func open(directories: [String], target: ServiceOpenTarget) {
        host.prepareForExplicitOpenIntentAtStartup()
        for directory in directories {
            switch target {
            case .window:
                host.createMainWindowForExternalOpen(workingDirectory: directory)
            case .workspace:
                openWorkspace(
                    forExternalDirectory: directory,
                    debugSource: "service.openTab"
                )
            }
        }
    }

    /// Adds a workspace for `workingDirectory` in the preferred main window,
    /// creating a new main window when no preferred window is available.
    public func openWorkspace(
        forExternalDirectory workingDirectory: String,
        debugSource: String
    ) {
        if host.addWorkspaceInPreferredMainWindowForExternalOpen(
            workingDirectory: workingDirectory,
            debugSource: debugSource
        ) {
            return
        }
        host.createMainWindowForExternalOpen(workingDirectory: workingDirectory)
    }
}
