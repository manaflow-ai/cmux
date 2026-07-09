/// Which surface an external open intent targets for each resolved directory.
///
/// Carried by the Finder NSServices `openWindow`/`openTab` entry points into
/// ``ExternalOpenIntentCoordinator/open(directories:target:)`` so the residual
/// decision/loop layer knows whether to spawn a window per directory or add a
/// workspace in the preferred main window.
public enum ServiceOpenTarget: Sendable {
    /// Open each resolved directory in a brand-new main window.
    case window
    /// Open each resolved directory as a workspace in the preferred main
    /// window, falling back to a new window when none is available.
    case workspace
}
