// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// The socket directory must be a real directory owned by this user with
/// mode 0700; a symlink or another user's directory could hand the socket
/// to someone else.
enum PrivateDirectory {
    static func prepare(_ path: String) -> Bool {
        if mkdir(path, 0o700) != 0, errno != EEXIST { return false }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR else { return false }
        return info.st_mode & 0o777 == 0o700 || fchmod(descriptor, 0o700) == 0
    }
}
