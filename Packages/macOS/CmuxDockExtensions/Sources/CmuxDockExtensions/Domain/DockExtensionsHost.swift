import Foundation

/// App-side effects the extensions domain cannot perform itself. Implemented
/// by the app target (which owns the Dock stores and settings) and injected
/// into ``DockExtensionsStore`` at the composition root — the package never
/// reaches into app state directly.
@MainActor
public protocol DockExtensionsHost: AnyObject {
    /// The running app's marketing version (e.g. `"0.31.0"`), compared against
    /// a manifest's `minCmuxVersion`.
    var currentAppVersion: String { get }

    /// Opens one extension pane as a Dock terminal tab in the active window's
    /// Dock. Returns `false` when no Dock is available (no main window).
    func openExtensionPane(_ request: DockExtensionPaneOpenRequest) -> Bool

    /// Called after a successful install: enables the Dock beta feature (the
    /// locked product decision — installing an extension turns the Dock on).
    /// Must not raise windows or steal focus — it also runs for socket/CLI
    /// installs; GUI surfaces do their own reveal.
    func activateDockForExtensions()
}
