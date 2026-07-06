import Foundation

/// Typed failures across the Dock-extensions install/run pipeline. Every case
/// carries a user-presentable ``errorDescription`` (localized keys live in the
/// app's string catalog; SwiftPM test runs fall back to the English default).
public enum DockExtensionError: Error, Equatable, LocalizedError {
    /// The install input is not a valid `owner/repo[/subdir]` source.
    case invalidSource(String)
    /// The extension's on-disk manifest changed since consent; reinstall or
    /// update to re-consent before its panes can open.
    case needsReconsent(id: String)
    /// `git` is not usable (typically missing Xcode Command Line Tools).
    case gitUnavailable(detail: String)
    /// A git operation exited non-zero.
    case gitFailed(operation: String, detail: String)
    /// No `cmux-extension.json` exists at the expected location.
    case manifestNotFound(path: String)
    /// The manifest file exceeds ``DockExtensionManifest/maximumFileSize``.
    case manifestTooLarge(limitBytes: Int)
    /// The manifest failed validation; each element is one field error.
    case manifestInvalid([String])
    /// The manifest declares a `manifestVersion` this cmux does not support.
    case unsupportedManifestVersion(Int)
    /// The manifest's `minCmuxVersion` is newer than the running app.
    case minCmuxVersionNotSatisfied(required: String, current: String)
    /// The manifest does not apply to this platform.
    case platformNotSupported(id: String)
    /// Another installed extension already uses this id.
    case duplicateId(String)
    /// A build step exited non-zero.
    case buildFailed(command: String, exitCode: Int32, logTail: String)
    /// A build step exceeded its timeout.
    case buildTimedOut(command: String)
    /// No installed extension has this id.
    case notInstalled(id: String)
    /// The extension has no pane with this id (or it is unavailable here).
    case paneNotFound(qualifiedId: String)
    /// The extension is installed but disabled.
    case extensionDisabled(id: String)
    /// The linked directory does not exist or is not a directory.
    case linkedDirectoryMissing(path: String)
    /// Moving the staged checkout into place failed.
    case stagingFailed(detail: String)
    /// The app-side host bridge is unavailable (startup teardown races).
    case hostUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let input):
            return String(
                localized: "dockExtensions.error.invalidSource",
                defaultValue: "\"\(input)\" is not a valid extension source. Use owner/repo or owner/repo/subdirectory."
            )
        case .needsReconsent(let id):
            return String(
                localized: "dockExtensions.error.needsReconsent",
                defaultValue: "Extension \"\(id)\" changed on disk since you approved it. Update or reinstall it to review the new commands."
            )
        case .gitUnavailable:
            // The raw spawn detail stays in the associated value (for logs and
            // socket error data); the presented copy is cmux-terms + action.
            return String(
                localized: "dockExtensions.error.gitUnavailable",
                defaultValue: "git is not available. Install the Xcode Command Line Tools (xcode-select --install) and try again."
            )
        case .gitFailed(_, let detail):
            // Internal git subcommand names stay out of the presented copy;
            // the (tail-truncated) git detail is the actionable cause the
            // user needs ("Repository not found", "no branch named x", …).
            return String(
                localized: "dockExtensions.error.gitFailed",
                defaultValue: "Couldn't fetch the extension from its Git repository: \(detail)"
            )
        case .manifestNotFound(let path):
            return String(
                localized: "dockExtensions.error.manifestNotFound",
                defaultValue: "No cmux-extension.json found at \(path)."
            )
        case .manifestTooLarge(let limitBytes):
            return String(
                localized: "dockExtensions.error.manifestTooLarge",
                defaultValue: "cmux-extension.json is larger than \(limitBytes) bytes."
            )
        case .manifestInvalid(let issues):
            return String(
                localized: "dockExtensions.error.manifestInvalid",
                defaultValue: "Invalid cmux-extension.json: \(issues.joined(separator: "; "))"
            )
        case .unsupportedManifestVersion(let version):
            return String(
                localized: "dockExtensions.error.unsupportedManifestVersion",
                defaultValue: "This extension requires a newer cmux (manifestVersion \(version))."
            )
        case .minCmuxVersionNotSatisfied(let required, let current):
            return String(
                localized: "dockExtensions.error.minCmuxVersionNotSatisfied",
                defaultValue: "This extension requires cmux \(required) or newer (you have \(current))."
            )
        case .platformNotSupported(let id):
            return String(
                localized: "dockExtensions.error.platformNotSupported",
                defaultValue: "Extension \"\(id)\" does not support macOS."
            )
        case .duplicateId(let id):
            return String(
                localized: "dockExtensions.error.duplicateId",
                defaultValue: "An extension with id \"\(id)\" is already installed from a different source. Uninstall it first."
            )
        case .buildFailed(let command, let exitCode, let logTail):
            return String(
                localized: "dockExtensions.error.buildFailed",
                defaultValue: "Build step failed (exit \(exitCode)): \(command)\n\(logTail)"
            )
        case .buildTimedOut(let command):
            return String(
                localized: "dockExtensions.error.buildTimedOut",
                defaultValue: "Build step timed out: \(command)"
            )
        case .notInstalled(let id):
            return String(
                localized: "dockExtensions.error.notInstalled",
                defaultValue: "No installed extension with id \"\(id)\"."
            )
        case .paneNotFound(let qualifiedId):
            return String(
                localized: "dockExtensions.error.paneNotFound",
                defaultValue: "No extension pane \"\(qualifiedId)\"."
            )
        case .extensionDisabled(let id):
            return String(
                localized: "dockExtensions.error.extensionDisabled",
                defaultValue: "Extension \"\(id)\" is disabled. Enable it in Settings → Extensions."
            )
        case .linkedDirectoryMissing(let path):
            return String(
                localized: "dockExtensions.error.linkedDirectoryMissing",
                defaultValue: "No directory at \(path)."
            )
        case .stagingFailed(let detail):
            return String(
                localized: "dockExtensions.error.stagingFailed",
                defaultValue: "Could not move the extension into place: \(detail)"
            )
        case .hostUnavailable:
            return String(
                localized: "dockExtensions.error.hostUnavailable",
                defaultValue: "cmux is not ready to open extension panes yet. Try again."
            )
        }
    }
}
