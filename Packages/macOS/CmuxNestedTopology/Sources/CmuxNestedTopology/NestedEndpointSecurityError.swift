#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
public import Foundation

/// Security failures raised while validating a nested-provider Unix socket endpoint.
///
/// Error messages intentionally omit the raw socket path so default diagnostics
/// and telemetry cannot leak endpoint locators.
public enum NestedEndpointSecurityError: Error, Hashable, Sendable, LocalizedError {
    /// Path was empty.
    case emptyPath
    /// Path was not absolute.
    case notAbsolutePath
    /// Path exceeded the platform Unix-socket address bound.
    case pathTooLong(maxUTF8ByteCount: Int)
    /// Path contained a NUL or other illegal byte sequence.
    case illegalPathBytes
    /// Final path component resolved as a symbolic link (rejected; no follow).
    case symlinkRejected
    /// Path does not exist.
    case missing
    /// Path exists but is not a Unix-domain socket.
    case notUnixSocket
    /// Socket owner UID does not match the expected effective UID.
    case wrongOwner(expected: UInt32, actual: UInt32)
    /// Socket mode grants group/other access (must be owner-only, e.g. `0600`).
    case permissiveMode(mode: UInt32)
    /// Path was inaccessible (`lstat` failed for a reason other than missing).
    case inaccessible(errnoCode: Int32)
    /// Pre-connect and post-connect file identities disagreed (path swap).
    case identityMismatch(
        expected: NestedUnixSocketFileIdentity,
        actual: NestedUnixSocketFileIdentity
    )

    public var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "Nested provider socket path is empty."
        case .notAbsolutePath:
            return "Nested provider socket path must be absolute."
        case .pathTooLong:
            return "Nested provider socket path is too long."
        case .illegalPathBytes:
            return "Nested provider socket path contains illegal bytes."
        case .symlinkRejected:
            return "Nested provider socket path must not be a symbolic link."
        case .missing:
            return "Nested provider socket path does not exist."
        case .notUnixSocket:
            return "Nested provider endpoint is not a Unix-domain socket."
        case .wrongOwner:
            return "Nested provider socket is not owned by this process user."
        case .permissiveMode:
            return "Nested provider socket permissions allow group or other access."
        case .inaccessible:
            return "Nested provider socket path is inaccessible."
        case .identityMismatch:
            return "Nested provider socket file identity changed around connect."
        }
    }

    /// Coarse error class suitable for redacted telemetry (never includes paths).
    public var telemetryErrorClass: String {
        switch self {
        case .emptyPath: return "empty_path"
        case .notAbsolutePath: return "not_absolute_path"
        case .pathTooLong: return "path_too_long"
        case .illegalPathBytes: return "illegal_path_bytes"
        case .symlinkRejected: return "symlink_rejected"
        case .missing: return "missing"
        case .notUnixSocket: return "not_unix_socket"
        case .wrongOwner: return "wrong_owner"
        case .permissiveMode: return "permissive_mode"
        case .inaccessible: return "inaccessible"
        case .identityMismatch: return "identity_mismatch"
        }
    }
}
