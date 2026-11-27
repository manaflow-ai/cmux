import Darwin
internal import Foundation

/// Private directory holding the local end of the baked-VM daemon socket
/// forward.
///
/// Daemon RPC on that forward carries no credential of its own, so only the
/// current user may reach the socket. The directory is a fresh `mkdtemp`
/// directory (mode 0700, never a pre-existing path) under a parent other
/// users cannot rename entries in, and ssh binds ``socketPath`` inside it
/// with `StreamLocalBindMask=0177`. The client also checks the peer uid
/// after connecting.
struct RemoteDaemonForwardSocketDirectory: Sendable {
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminating NUL,
    /// and ssh binds the exact path.
    static let maxSocketPathBytes = 103
    static let socketName = "d.sock"

    let path: String

    var socketPath: String { path + "/" + Self.socketName }

    /// Creates a directory under the first usable parent. The default
    /// parents are the per-user temporary directory, then `/private/tmp`
    /// (sticky) when the former is missing or yields a path ssh would not
    /// bind verbatim.
    static func create(parents: [String] = defaultParents()) throws -> RemoteDaemonForwardSocketDirectory {
        var lastError = ENOENT
        for parent in parents {
            let parent = parent.count > 1 && parent.hasSuffix("/") ? String(parent.dropLast()) : parent
            let template = parent + "/cmuxd.XXXXXX"
            guard isBindablePath(template + "/" + socketName), isTrustedParent(parent) else { continue }

            var buffer = Array(template.utf8CString)
            let created = buffer.withUnsafeMutableBufferPointer { pointer in
                mkdtemp(pointer.baseAddress!) != nil
            }
            guard created else {
                lastError = errno
                continue
            }
            let directory = RemoteDaemonForwardSocketDirectory(
                path: buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            )
            guard directory.isPrivate else {
                rmdir(directory.path)
                lastError = EPERM
                continue
            }
            return directory
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(lastError), userInfo: [
            NSLocalizedDescriptionKey: String(cString: strerror(lastError)),
        ])
    }

    static func defaultParents() -> [String] {
        var parents: [String] = []
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if length > 0 {
            var buffer = [CChar](repeating: 0, count: length)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 {
                parents.append(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
        }
        parents.append("/private/tmp")
        return parents
    }

    /// Whether ssh binds `path` as written: short enough for `sun_path`, and
    /// free of the forward-spec separator and of the `%`, `$` and `~`
    /// expansions newer OpenSSH applies to Unix forward paths.
    static func isBindablePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= maxSocketPathBytes else { return false }
        return path.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "/"), UInt8(ascii: "."), UInt8(ascii: "_"),
                 UInt8(ascii: "+"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }

    /// A parent owned by this user or root that no one else can rename
    /// entries in (not group/other writable, or sticky).
    static func isTrustedParent(_ parent: String) -> Bool {
        var info = stat()
        guard stat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        guard info.st_uid == geteuid() || info.st_uid == 0 else { return false }
        return info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0
    }

    /// The created directory is a real directory owned by this user with no
    /// group or other permissions.
    var isPrivate: Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR
            && info.st_uid == geteuid()
            && info.st_mode & 0o077 == 0
    }

    /// Removes the forward socket and the directory. Never recursive: a
    /// directory holding anything else is left in place.
    func remove() {
        unlink(socketPath)
        rmdir(path)
    }
}
