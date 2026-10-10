public import Darwin
internal import Foundation

public extension SocketTransport {
    /// The peer PID of a connected Unix domain socket via `LOCAL_PEERPID`.
    ///
    /// Used with ``isProcessDescendant(_:of:)`` to enforce the `cmuxOnly`
    /// access mode's ancestry check on accepted clients:
    ///
    /// ```swift
    /// if let pid = transport.peerProcessID(of: clientSocket),
    ///    !transport.isProcessDescendant(pid, of: getpid()) {
    ///     // refuse: client was not started inside cmux
    /// }
    /// ```
    /// - Parameter socket: A connected Unix domain socket descriptor.
    /// - Returns: The peer's PID, or `nil` when the lookup failed (commonly
    ///   because the peer already disconnected).
    func peerProcessID(of socket: Int32) -> pid_t? {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        if result != 0 || pid <= 0 {
            return nil
        }
        return pid
    }

    /// Whether the socket's peer ran as the same UID as this process, via
    /// `LOCAL_PEERCRED`. Works even after the peer has disconnected (unlike
    /// `LOCAL_PEERPID`).
    ///
    /// The fallback check when ``peerProcessID(of:)`` returns `nil` because a
    /// short-lived client already disconnected; same security boundary as the
    /// socket file's 0600 permissions.
    /// - Parameter socket: A connected Unix domain socket descriptor.
    /// - Returns: `true` when the peer's effective UID matches `getuid()`.
    func peerHasSameUID(_ socket: Int32) -> Bool {
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen)
        guard result == 0 else { return false }
        return cred.cr_uid == getuid()
    }

    /// Whether `pid` is `ancestorPid` or one of its descendants, walking the
    /// process tree via `sysctl`.
    ///
    /// Pairs with ``peerProcessID(of:)`` for the `cmuxOnly` ancestry check;
    /// see that symbol for a usage example.
    /// - Parameters:
    ///   - pid: The process to test.
    ///   - ancestorPid: The candidate ancestor (the cmux process).
    /// - Returns: `true` when `pid`'s parent chain reaches `ancestorPid`
    ///   within 128 levels.
    func isProcessDescendant(_ pid: pid_t, of ancestorPid: pid_t) -> Bool {
        var current = pid
        // Walk up to 128 levels to avoid infinite loops from kernel bugs
        for _ in 0..<128 {
            if current == ancestorPid {
                return true
            }
            if current <= 1 {
                return false
            }
            let parent = parentProcessID(of: current)
            if parent == current || parent < 0 {
                return false
            }
            current = parent
        }
        return false
    }

    /// The parent PID of `pid` via `sysctl`, or `-1` on failure.
    private func parentProcessID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return -1
        }
        return info.kp_eproc.e_ppid
    }
}
