#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
public import Foundation

/// Validates a nested-provider endpoint before and after connect.
///
/// Rules (Herdr / nested-topology security contract):
/// - local Unix-domain socket only (path form; no network transport)
/// - absolute path; final component must not be a symlink (`lstat`, no follow)
/// - owned by the expected UID (default: `geteuid()`)
/// - restrictive mode: no group/other bits (`st_mode & 0o077 == 0`)
/// - capture device/inode identity and recheck after connect
public struct NestedUnixSocketEndpointValidator: NestedEndpointValidating, Sendable {
    /// Maximum UTF-8 byte length accepted for a Unix socket path (matches Darwin `sockaddr_un`).
    public static let maxSocketPathUTF8ByteCount = 103

    /// Expected socket owner UID.
    public var expectedOwnerUID: uid_t
    /// When non-zero group/other bits are present, validation fails.
    public var rejectGroupOtherAccess: Bool

    /// Creates a validator.
    ///
    /// - Parameters:
    ///   - expectedOwnerUID: Required socket owner. Defaults to the process effective UID.
    ///   - rejectGroupOtherAccess: Whether modes granting group/other access are rejected.
    public init(
        expectedOwnerUID: uid_t = geteuid(),
        rejectGroupOtherAccess: Bool = true
    ) {
        self.expectedOwnerUID = expectedOwnerUID
        self.rejectGroupOtherAccess = rejectGroupOtherAccess
    }

    /// Validates `path` before connecting and returns the pinned endpoint identity.
    public func validatePreConnect(path: String) throws -> NestedAttachmentEndpoint {
        let canonical = try canonicalize(path)
        let status = try lstatSocket(at: canonical)
        let identity = NestedUnixSocketFileIdentity(statBuffer: status)
        let permissionBits = UInt32(status.st_mode & mode_t(0o777))
        return NestedAttachmentEndpoint(
            canonicalPath: canonical,
            fileIdentity: identity,
            ownerUID: UInt32(status.st_uid),
            permissionBits: permissionBits
        )
    }

    /// Rechecks that `path` still refers to the same socket file identity.
    public func revalidateIdentity(
        path: String,
        expected: NestedUnixSocketFileIdentity
    ) throws {
        let canonical = try canonicalize(path)
        let status = try lstatSocket(at: canonical)
        let actual = NestedUnixSocketFileIdentity(statBuffer: status)
        guard actual == expected else {
            throw NestedEndpointSecurityError.identityMismatch(expected: expected, actual: actual)
        }
    }

    /// Canonicalizes an absolute path without following a final-component symlink.
    ///
    /// Important: do **not** run `standardizingPath` / `resolvingSymlinksInPath` on the
    /// full path. On Linux, swift-corelibs Foundation's `standardizingPath` follows a
    /// final symlink, which would defeat the no-symlink-confusion check.
    ///
    /// Parent resolution preserves OS symlink + `..` semantics: the final component is
    /// taken from the raw path, and only the raw parent is symlink-resolved.
    public func canonicalize(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NestedEndpointSecurityError.emptyPath
        }
        guard !trimmed.utf8.contains(0) else {
            throw NestedEndpointSecurityError.illegalPathBytes
        }
        guard trimmed.hasPrefix("/") else {
            throw NestedEndpointSecurityError.notAbsolutePath
        }
        guard trimmed.utf8.count <= Self.maxSocketPathUTF8ByteCount else {
            throw NestedEndpointSecurityError.pathTooLong(
                maxUTF8ByteCount: Self.maxSocketPathUTF8ByteCount
            )
        }

        let last = (trimmed as NSString).lastPathComponent
        guard !last.isEmpty, last != "/", last != ".", last != ".." else {
            throw NestedEndpointSecurityError.illegalPathBytes
        }
        let parent = (trimmed as NSString).deletingLastPathComponent
        guard parent.hasPrefix("/") else {
            throw NestedEndpointSecurityError.notAbsolutePath
        }
        let resolvedParent = (parent as NSString).resolvingSymlinksInPath
        let candidate = (resolvedParent as NSString).appendingPathComponent(last)
        guard candidate.utf8.count <= Self.maxSocketPathUTF8ByteCount else {
            throw NestedEndpointSecurityError.pathTooLong(
                maxUTF8ByteCount: Self.maxSocketPathUTF8ByteCount
            )
        }
        return candidate
    }

    private func lstatSocket(at path: String) throws -> stat {
        var status = stat()
        let result = lstat(path, &status)
        if result != 0 {
            let code = errno
            if code == ENOENT {
                throw NestedEndpointSecurityError.missing
            }
            throw NestedEndpointSecurityError.inaccessible(errnoCode: code)
        }

        let fileType = status.st_mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFLNK) {
            throw NestedEndpointSecurityError.symlinkRejected
        }
        guard fileType == mode_t(S_IFSOCK) else {
            throw NestedEndpointSecurityError.notUnixSocket
        }
        guard status.st_uid == expectedOwnerUID else {
            throw NestedEndpointSecurityError.wrongOwner(
                expected: UInt32(expectedOwnerUID),
                actual: UInt32(status.st_uid)
            )
        }
        if rejectGroupOtherAccess {
            let groupOther = status.st_mode & mode_t(0o077)
            if groupOther != 0 {
                throw NestedEndpointSecurityError.permissiveMode(
                    mode: UInt32(status.st_mode & mode_t(0o777))
                )
            }
        }
        return status
    }
}

/// Endpoint validation surface used by ``NestedTopologyAttachmentCoordinator``.
public protocol NestedEndpointValidating: Sendable {
    /// Validates a path before connecting.
    func validatePreConnect(path: String) throws -> NestedAttachmentEndpoint
    /// Rechecks pinned identity after connecting (or immediately before use).
    func revalidateIdentity(path: String, expected: NestedUnixSocketFileIdentity) throws
}
