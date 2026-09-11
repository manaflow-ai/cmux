public import Foundation

/// Validation failures produced while preparing a diff-viewer session.
public enum CmuxDiffViewerSessionError: Int, Equatable, Error, LocalizedError, Sendable {
    /// The capability token does not match the accepted syntax.
    case invalidToken = 1

    /// The allowlist has no entries.
    case emptyAllowlist = 2

    /// An allowlist entry has an invalid path or MIME type.
    case invalidEntry = 3

    /// An allowlisted file is outside the trusted root or is not readable.
    case unreadableFile = 4

    /// Two allowlist entries expose the same request path.
    case duplicateEntry = 5

    /// The allowlist exceeds the sidecar-compatible entry limit.
    case allowlistTooLarge = 6

    /// The manifest is missing, malformed, token-mismatched, or contains remote entries.
    case invalidManifest = 7

    /// The manifest exceeds the byte limit enforced before JSON decoding.
    case manifestTooLarge = 8

    /// The trusted root is not a current-user-owned directory.
    case unsafeTrustedRoot = 9

    /// A localized description suitable for propagation through the control API.
    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            String(
                localized: "diffViewer.error.invalidToken",
                defaultValue: "Invalid diff viewer token",
                bundle: .module
            )
        case .emptyAllowlist:
            String(
                localized: "diffViewer.error.emptyAllowlist",
                defaultValue: "Diff viewer allowlist is empty",
                bundle: .module
            )
        case .invalidEntry:
            String(
                localized: "diffViewer.error.invalidEntry",
                defaultValue: "Invalid diff viewer allowlist entry",
                bundle: .module
            )
        case .unreadableFile:
            String(
                localized: "diffViewer.error.unreadableFile",
                defaultValue: "Diff viewer file is not readable",
                bundle: .module
            )
        case .duplicateEntry:
            String(
                localized: "diffViewer.error.duplicateEntry",
                defaultValue: "Duplicate diff viewer allowlist entry",
                bundle: .module
            )
        case .allowlistTooLarge:
            String(
                localized: "diffViewer.error.allowlistTooLarge",
                defaultValue: "Diff viewer allowlist is too large",
                bundle: .module
            )
        case .invalidManifest:
            String(
                localized: "diffViewer.error.invalidManifest",
                defaultValue: "Invalid diff viewer manifest",
                bundle: .module
            )
        case .manifestTooLarge:
            String(
                localized: "diffViewer.error.manifestTooLarge",
                defaultValue: "Diff viewer manifest is too large",
                bundle: .module
            )
        case .unsafeTrustedRoot:
            String(
                localized: "diffViewer.error.unsafeTrustedRoot",
                defaultValue: "Diff viewer trusted directory is unsafe",
                bundle: .module
            )
        }
    }
}
