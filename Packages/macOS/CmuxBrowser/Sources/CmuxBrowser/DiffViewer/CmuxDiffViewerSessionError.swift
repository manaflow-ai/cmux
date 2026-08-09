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
            "Invalid diff viewer token"
        case .emptyAllowlist:
            "Diff viewer allowlist is empty"
        case .invalidEntry:
            "Invalid diff viewer allowlist entry"
        case .unreadableFile:
            "Diff viewer file is not readable"
        case .duplicateEntry:
            "Duplicate diff viewer allowlist entry"
        case .allowlistTooLarge:
            String(
                localized: "diffViewer.error.allowlistTooLarge",
                defaultValue: "Diff viewer allowlist is too large",
                bundle: .main
            )
        case .invalidManifest:
            "Invalid diff viewer manifest"
        case .manifestTooLarge:
            "Diff viewer manifest is too large"
        case .unsafeTrustedRoot:
            "Diff viewer trusted directory is unsafe"
        }
    }
}
