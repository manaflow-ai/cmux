// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Where the helper may put its socket, and the checks on every directory
/// on the way there. Fleet Macs run several slot users on one machine, so
/// another local user must never be able to own, swap or read the socket.
///
/// Allowed roots:
/// - this user's Darwin temp directory (`confstr(_CS_DARWIN_USER_TEMP_DIR)`,
///   `/var/folders/../T/`, about 50 bytes, owned by this user and 0700);
/// - `/tmp` (`/private/tmp`), only as a fallback: root-owned and sticky, so
///   another user cannot rename or remove a directory we own there.
///
/// Below the root, every component is created with `mkdirat(0700)` or taken
/// as it is, opened with `O_NOFOLLOW`, and checked with `fstat` on that open
/// descriptor (never by path): a real directory owned by this user, not
/// writable by group or others. The socket's own directory is set to 0700.
/// A symlink, another user's directory, or a shared writable directory on
/// the way refuses the start.
enum PrivateDirectory {
    /// This user's Darwin temp directory, without a trailing slash, or nil.
    static func userTemporaryRoot() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        let path = String(cString: buffer)
        guard path.hasPrefix("/") else { return nil }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static let sharedTemporaryRoots = ["/private/tmp", "/tmp"]

    /// The allowed root that contains `directory`, and the components below it.
    static func split(_ directory: String) -> (root: String, shared: Bool, components: [Substring])? {
        var roots: [(String, Bool)] = sharedTemporaryRoots.map { ($0, true) }
        if let user = userTemporaryRoot() { roots.insert((user, false), at: 0) }
        for (root, shared) in roots where directory.hasPrefix(root + "/") {
            let components = directory.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
            return (root, shared, components)
        }
        return nil
    }

    /// Creates or takes `directory` (see the type comment). True when the
    /// whole chain is private to this user.
    static func prepare(_ directory: String) -> Bool {
        guard let parts = split(directory) else { return false }
        let (root, shared, components) = parts
        let me = geteuid()
        var current = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { return false }
        defer { close(current) }
        var info = stat()
        guard fstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        if shared {
            // /tmp: root-owned and sticky, or another user could swap our directory.
            guard info.st_uid == 0, info.st_mode & S_ISVTX != 0 else { return false }
        } else {
            guard info.st_uid == me, info.st_mode & 0o022 == 0 else { return false }
        }
        for (index, component) in components.enumerated() {
            let name = String(component)
            if mkdirat(current, name, 0o700) != 0, errno != EEXIST { return false }
            let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return false }
            close(current)
            current = next
            guard fstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == me else { return false }
            if index == components.count - 1 {
                guard info.st_mode & 0o777 == 0o700 || fchmod(current, 0o700) == 0 else { return false }
            } else if info.st_mode & 0o022 != 0 {
                return false
            }
        }
        return true
    }
}
