import Foundation

/// App-side effects the extensions domain cannot perform itself. Implemented
/// by the app target (which owns windows and settings) and injected
/// into ``DockExtensionsStore`` at the composition root — the package never
/// reaches into app state directly.
@MainActor
public protocol DockExtensionsHost: AnyObject {
    /// The running app's marketing version (e.g. `"0.31.0"`), compared against
    /// a manifest's `minCmuxVersion`.
    var currentAppVersion: String { get }

    /// Opens one extension pane as a terminal pane in the active workspace.
    /// Returns `false` when no main workspace is available.
    func openExtensionPane(_ request: DockExtensionPaneOpenRequest) -> Bool

    /// Called after a successful install. Must not raise windows or steal focus
    /// because it also runs for socket/CLI installs.
    func activateDockForExtensions()
}
