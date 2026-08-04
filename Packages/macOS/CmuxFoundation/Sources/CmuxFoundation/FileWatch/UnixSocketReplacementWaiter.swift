import Darwin
public import Foundation

/// Synchronously waits for one Unix-domain socket path to name a new inode.
///
/// This is a bounded OS wait for synchronous command-line entry points. The
/// parent directory is observed with `kqueue`; unrelated directory changes and
/// a bound-but-dead socket at the original inode do not satisfy the wait.
public struct UnixSocketReplacementWaiter: Sendable {
    public enum Outcome: Sendable, Equatable {
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

    /// Registration seam used by behavior tests to mutate only after each
    /// kernel watch is active, avoiding timing guesses.
    func wait(
        at path: String,
        replacing connectedIdentity: String?,
        timeout: TimeInterval,
        onRegistered: @Sendable () -> Void
    ) -> Outcome {
        guard timeout.isFinite, timeout > 0 else {
            return .unavailable
        }

        let clock = ContinuousClock()
        // Keep Duration/timespec conversion inside signed 32-bit seconds even
        // for a nonsensically large but finite caller timeout.
        let boundedTimeout = min(timeout, TimeInterval(Int32.max))
        let deadline = clock.now.advanced(by: .seconds(boundedTimeout))
        while true {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return .timedOut }
            guard let watchDirectory = existingWatchDirectory(forPath: path) else {
                return .unavailable
            }

            let watchFD = open(watchDirectory, O_EVTONLY)
            guard watchFD >= 0 else { return .unavailable }
            let eventQueueFD = kqueue()
            guard eventQueueFD >= 0 else {
                Darwin.close(watchFD)
                return .unavailable
            }

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
                Darwin.close(eventQueueFD)
                Darwin.close(watchFD)
                return .unavailable
            }
            onRegistered()

            // Register first, then inspect the inode. This closes the race in
            // which replacement occurs between the caller's snapshot and watch
            // installation.
            if let currentIdentity = socketIdentity(at: path),
               currentIdentity != connectedIdentity {
                Darwin.close(eventQueueFD)
                Darwin.close(watchFD)
                return .replaced
            }

            // If a missing direct parent appeared, the old ancestor watch is no
            // longer sufficient: later writes below the new directory do not
            // notify its ancestor. Re-register on the closest existing parent
            // before waiting.
            if existingWatchDirectory(forPath: path) != watchDirectory {
                Darwin.close(eventQueueFD)
                Darwin.close(watchFD)
                continue
            }

            let refreshedRemaining = clock.now.duration(to: deadline)
            guard refreshedRemaining > .zero else {
                Darwin.close(eventQueueFD)
                Darwin.close(watchFD)
                return .timedOut
            }
            let components = refreshedRemaining.components
            var wait = timespec(
                tv_sec: Int(components.seconds),
                tv_nsec: Int(components.attoseconds / 1_000_000_000)
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
            Darwin.close(eventQueueFD)
            Darwin.close(watchFD)

            if result > 0 {
                // Parent directories are shared. Re-register, recheck the exact
                // socket, and remain under the original monotonic deadline.
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
