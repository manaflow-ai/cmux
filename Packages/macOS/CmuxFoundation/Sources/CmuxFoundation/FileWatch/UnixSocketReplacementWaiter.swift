import Darwin
public import Foundation

/// Synchronously waits for one Unix-domain socket path to name a new inode.
///
/// This is a bounded OS wait for synchronous command-line entry points. The
/// parent directory is observed with `kqueue`; unrelated directory changes and
/// a bound-but-dead socket at the original inode do not satisfy the wait.
public struct UnixSocketReplacementWaiter: Sendable {
    public enum Outcome: Sendable {
        case replaced
        case timedOut
        case unavailable
    }

    public init() {}

    /// Stable device/inode identity for a Unix-domain socket at `path`.
    public func socketIdentity(at path: String) -> String? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            return nil
        }
        return "\(UInt64(metadata.st_dev)):\(UInt64(metadata.st_ino))"
    }

    /// Waits until `path` names a socket other than `connectedIdentity`.
    @discardableResult
    public func wait(
        at path: String,
        replacing connectedIdentity: String?,
        timeout: TimeInterval
    ) -> Outcome {
        wait(
            at: path,
            replacing: connectedIdentity,
            timeout: timeout,
            onRegistered: {}
        )
    }

    /// Registration seam used by behavior tests to mutate only after the
    /// kernel watch is active, avoiding timing guesses.
    func wait(
        at path: String,
        replacing connectedIdentity: String?,
        timeout: TimeInterval,
        onRegistered: @Sendable () -> Void
    ) -> Outcome {
        guard timeout > 0,
              let watchDirectory = existingWatchDirectory(forPath: path) else {
            return .unavailable
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else { return .unavailable }
        defer { Darwin.close(watchFD) }

        let eventQueueFD = kqueue()
        guard eventQueueFD >= 0 else { return .unavailable }
        defer { Darwin.close(eventQueueFD) }

        var registration = kevent(
            ident: UInt(watchFD),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: UInt32(
                NOTE_WRITE | NOTE_RENAME | NOTE_DELETE | NOTE_ATTRIB
                    | NOTE_EXTEND | NOTE_LINK
            ),
            data: 0,
            udata: nil
        )
        guard kevent(
            eventQueueFD,
            &registration,
            1,
            nil,
            0,
            nil
        ) == 0 else {
            return .unavailable
        }
        onRegistered()

        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            // Register first, then inspect the inode. This closes the race in
            // which replacement occurs between the caller's snapshot and watch
            // installation.
            if let currentIdentity = socketIdentity(at: path),
               currentIdentity != connectedIdentity {
                return .replaced
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .timedOut }
            let seconds = floor(remaining)
            var wait = timespec(
                tv_sec: Int(seconds),
                tv_nsec: Int((remaining - seconds) * 1_000_000_000)
            )
            var event = kevent()
            let result = kevent(
                eventQueueFD,
                nil,
                0,
                &event,
                1,
                &wait
            )
            if result > 0 {
                // Parent directories are shared. Recheck the exact socket and
                // remain under the original absolute deadline.
                continue
            }
            if result == 0 { return .timedOut }
            if errno != EINTR { return .unavailable }
        }
    }

    private func existingWatchDirectory(forPath path: String) -> String? {
        let fileManager = FileManager.default
        var candidate = URL(
            fileURLWithPath: (path as NSString).deletingLastPathComponent,
            isDirectory: true
        )
        while !candidate.path.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return nil
    }
}
