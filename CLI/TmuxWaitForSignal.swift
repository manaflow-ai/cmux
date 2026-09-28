import Darwin
import Foundation

/// The marker file behind `cmux wait-for`: `-S` creates it and a waiter
/// consumes it, so a signal sent before the wait still wakes the waiter.
///
/// Signals live in a private per-user directory, so no other user can plant,
/// redirect or fake one. Files are opened relative to the verified directory
/// and never through a symlink.
struct TmuxWaitForSignal {
    let path: String
    private let directoryPath: String
    private let fileName: String

    init(name: String) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        fileName = String(sanitized) + ".sig"
        directoryPath = Self.userTemporaryDirectory() + "cmux-wait-for"
        path = directoryPath + "/" + fileName
    }

    func signal() throws {
        let directory = try openDirectory()
        defer { Darwin.close(directory) }
        let fd = fileName.withCString {
            Darwin.openat(
                directory,
                $0,
                O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard fd >= 0 else {
            throw CLIError(message: "wait-for could not create its signal file: \(Self.errorDescription())")
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid() else {
            throw CLIError(message: "wait-for signal file is not a private regular file: \(path)")
        }
    }

    /// Returns true once the signal has arrived and been consumed, false on timeout.
    /// `watching` runs once, after the directory watch is registered and the
    /// first check found no signal, so any signal sent after it wakes this wait.
    func wait(timeout: TimeInterval, watching: () -> Void = {}) throws -> Bool {
        let directory = try openDirectory()
        defer { Darwin.close(directory) }
        let queue = kqueue()
        guard queue >= 0 else {
            throw CLIError(message: "wait-for could not watch its signal directory: \(Self.errorDescription())")
        }
        defer { Darwin.close(queue) }
        // Register before the first check so a signal landing between them still wakes the wait.
        var change = kevent(
            ident: UInt(directory),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: UInt32(NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_LINK | NOTE_RENAME | NOTE_DELETE),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            throw CLIError(message: "wait-for could not watch its signal directory: \(Self.errorDescription())")
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        var announcedWatching = false
        while true {
            if consume(in: directory) {
                return true
            }
            if !announcedWatching {
                announcedWatching = true
                watching()
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return false
            }
            // Recheck at least once a second in case a directory event is missed.
            let interval = min(remaining, 1)
            var wake = timespec(
                tv_sec: Int(interval),
                tv_nsec: Int((interval - interval.rounded(.down)) * 1_000_000_000)
            )
            var event = kevent()
            _ = kevent(queue, nil, 0, &event, 1, &wake)
        }
    }

    /// Accepts only a regular file this user owns, then removes it. Another
    /// waiter on the same name may remove it first; the signal still counts.
    private func consume(in directory: Int32) -> Bool {
        var info = stat()
        let found = fileName.withCString {
            Darwin.fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard found, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else {
            return false
        }
        _ = fileName.withCString { Darwin.unlinkat(directory, $0, 0) }
        return true
    }

    /// Opens the signal directory, creating it 0700 when missing. It must be a
    /// real directory this user owns that no group or other user can write to.
    private func openDirectory() throws -> Int32 {
        guard directoryPath.hasPrefix("/") else {
            throw CLIError(message: "wait-for could not find the user temporary directory")
        }
        if Darwin.mkdir(directoryPath, mode_t(S_IRWXU)) != 0, errno != EEXIST {
            throw CLIError(message: "wait-for could not create its signal directory: \(Self.errorDescription())")
        }
        let fd = Darwin.open(directoryPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw CLIError(message: "wait-for could not open its signal directory: \(Self.errorDescription())")
        }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0 else {
            Darwin.close(fd)
            throw CLIError(message: "wait-for signal directory is not private: \(directoryPath)")
        }
        return fd
    }

    /// The per-user temporary directory. It comes from confstr rather than
    /// TMPDIR so both ends of a wait agree on it.
    private static func userTemporaryDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else {
            return ""
        }
        let directory = buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) } ?? ""
        }
        return directory.hasSuffix("/") ? directory : directory + "/"
    }

    private static func errorDescription() -> String {
        String(cString: strerror(errno))
    }
}
