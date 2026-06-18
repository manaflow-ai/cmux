internal import Foundation
internal import Darwin

extension SocketTransport {
    /// The advisory lock-file path for a socket path.
    ///
    /// - Parameter socketPath: The socket path the lock arbitrates.
    /// - Returns: The sibling lock-file path (`socketPath` + ``pathLockSuffix``).
    public func pathLockPath(for socketPath: String) -> String {
        socketPath + pathLockSuffix
    }

    /// Acquires the advisory lock that arbitrates ownership of `socketPath`.
    ///
    /// Creates (or opens) the sibling lock file with `O_NOFOLLOW`, validates it
    /// is a regular single-link file owned by the current user, and takes a
    /// non-blocking exclusive `flock(2)`. On success the caller owns the
    /// returned descriptor until ``releaseSocketPathLock(_:)``.
    ///
    /// - Parameter socketPath: The socket path whose lock to acquire.
    /// - Returns: The ``SocketPathLockAcquisition`` outcome.
    public func acquireSocketPathLock(for socketPath: String) -> SocketPathLockAcquisition {
        if let errnoCode = ensureSocketParentDirectoryExists(path: socketPath) {
            return .failed(SocketStageFailure(stage: "create_lock_directory", errnoCode: errnoCode))
        }

        let lockPath = pathLockPath(for: socketPath)
        var fd: Int32 = -1
        var lastErrno: Int32 = EIO
        for _ in 0..<3 {
            fd = open(lockPath, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            if fd >= 0 {
                break
            }

            let createErrno = errno
            guard createErrno == EEXIST else {
                return .failed(SocketStageFailure(stage: "open_lock", errnoCode: createErrno))
            }

            fd = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                break
            }

            lastErrno = errno
            guard lastErrno == ENOENT else {
                return .failed(SocketStageFailure(stage: "open_lock", errnoCode: lastErrno))
            }
        }
        guard fd >= 0 else {
            return .failed(SocketStageFailure(stage: "open_lock", errnoCode: lastErrno))
        }
        if let errnoCode = validateSocketPathLockFile(fd) {
            close(fd)
            return .failed(SocketStageFailure(stage: "open_lock", errnoCode: errnoCode))
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let errnoCode = errno
            close(fd)
            return .failed(SocketStageFailure(stage: "lock", errnoCode: errnoCode))
        }
        return .acquired(
            fd: fd,
            canReplaceRefusedSocket: pathLockHasReusableMarker(fd)
                || canReplaceUnmarkedRefusedSocket(at: socketPath)
        )
    }

    /// Validates the lock descriptor refers to a regular, single-link file
    /// owned by the current user; returns the failing `errno` otherwise.
    func validateSocketPathLockFile(_ fd: Int32) -> Int32? {
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            return errno
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return EINVAL
        }
        guard st.st_uid == getuid() else {
            return EACCES
        }
        guard st.st_nlink == 1 else {
            return EMLINK
        }
        return nil
    }

    /// Whether the lock file starts with the reusable marker.
    func pathLockHasReusableMarker(_ fd: Int32) -> Bool {
        let marker = Array(pathLockReusableMarker.utf8)
        var buffer = [UInt8](repeating: 0, count: marker.count)
        let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return ssize_t(-1)
            }
            return pread(fd, baseAddress, rawBuffer.count, 0)
        }
        return readCount == ssize_t(marker.count) && buffer == marker
    }

    /// Whether a refused socket at `path` may be replaced even without a
    /// reusable lock marker, based on the well-known cmux socket filenames
    /// (debug/nightly/staging and their tagged variants).
    func canReplaceUnmarkedRefusedSocket(at path: String) -> Bool {
        let filename = URL(fileURLWithPath: (path as NSString).standardizingPath)
            .lastPathComponent
            .lowercased()
        let recoverablePrefixes = ["cmux-debug-", "cmux-nightly-", "cmux-staging-"]
        return filename == "cmux-debug.sock" ||
            filename == "cmux-nightly.sock" ||
            filename == "cmux-staging.sock" ||
            recoverablePrefixes.contains { prefix in
                filename.hasPrefix(prefix) && filename.hasSuffix(".sock")
            }
    }

    /// Writes the reusable marker into the lock file, marking the socket path
    /// reclaimable by a future listener.
    ///
    /// - Parameter fd: The locked lock-file descriptor (no-op when negative).
    public func markSocketPathLockReusable(_ fd: Int32) {
        guard fd >= 0 else { return }
        let marker = Array(pathLockReusableMarker.utf8)
        guard ftruncate(fd, 0) == 0 else { return }
        guard lseek(fd, 0, SEEK_SET) >= 0 else { return }

        var written = 0
        while written < marker.count {
            let result = marker.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return ssize_t(-1)
                }
                return write(fd, baseAddress.advanced(by: written), marker.count - written)
            }
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else { return }
            written += Int(result)
        }
    }

    /// Unlocks and closes a lock descriptor (no-op for negative descriptors).
    ///
    /// - Parameter fd: The lock-file descriptor returned by ``acquireSocketPathLock(for:)``.
    public func releaseSocketPathLock(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    /// Whether a startup listener may claim `path`: either nothing exists there
    /// (and no foreign lock blocks it), or a socket exists whose lock is free
    /// and carries the reusable marker.
    ///
    /// - Parameter path: The socket path to evaluate.
    /// - Returns: True when a startup listener may claim the path.
    public func pathCanBeReclaimedForStartup(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return errno == ENOENT
                && pathHasAvailableLock(path, requireReusableMarker: false, treatMissingLockAsAvailable: true)
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            return false
        }
        return pathHasAvailableLock(path, requireReusableMarker: true, treatMissingLockAsAvailable: false)
    }

    func pathHasAvailableLock(
        _ path: String,
        requireReusableMarker: Bool,
        treatMissingLockAsAvailable: Bool
    ) -> Bool {
        let lockPath = pathLockPath(for: path)
        let fd = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            return treatMissingLockAsAvailable && errno == ENOENT
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        guard validateSocketPathLockFile(fd) == nil else {
            close(fd)
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        defer {
            releaseSocketPathLock(fd)
        }
        if requireReusableMarker {
            return pathLockHasReusableMarker(fd)
        }
        return true
    }
}
