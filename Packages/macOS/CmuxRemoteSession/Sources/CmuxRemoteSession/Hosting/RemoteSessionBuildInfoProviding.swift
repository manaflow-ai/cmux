public import CmuxCore
public import Foundation

/// App-build inputs the daemon bootstrap needs from `Bundle.main`, inverted
/// behind a seam so `Bundle.main` reads stay app-side (the checkpoint-5b
/// ruling) and package tests can supply fixed values.
///
/// Methods are funcs (not stored values) so the reads happen at the same
/// call-time points as the legacy controller's direct `Bundle.main` reads.
public protocol RemoteSessionBuildInfoProviding: Sendable {
    /// `CFBundleShortVersionString` of the running app, or `nil` when absent.
    func appVersion() -> String?
    /// The cmuxd-remote manifest release builds embed in the app's Info
    /// dictionary, or `nil` for dev builds without one.
    func embeddedDaemonManifest() -> WorkspaceRemoteDaemonManifest?
    /// The directory containing the app executable, used only as a dev-only
    /// repo-root discovery candidate for the local `go build` fallback.
    func executableDirectoryURL() -> URL?
}
