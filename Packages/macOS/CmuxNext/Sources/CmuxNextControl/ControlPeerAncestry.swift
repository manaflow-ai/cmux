import Darwin

/// Whether a socket peer was started inside this cmux: it descends from the
/// app, or from a process running a trusted executable (the bundled cmux
/// binary). Terminals descend from the cmux-tui terminal hosts, which are
/// not the app's children and outlive it, so the app pid alone admits none.
struct ControlPeerAncestry: Sendable {
    /// Parent pid and executable path of a process; nil when it is gone.
    var lookup: @Sendable (pid_t) -> (parent: pid_t, executable: String?)?

    static let system = ControlPeerAncestry { pid in
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        return (info.kp_eproc.e_ppid, path)
    }

    func isInside(_ pid: pid_t, ancestor: pid_t, executables: Set<String>) -> Bool {
        var current = pid
        for _ in 0..<128 {
            if current == ancestor { return true }
            if current <= 1 { return false }
            guard let process = lookup(current) else { return false }
            if let path = process.executable, executables.contains(path) { return true }
            if process.parent == current || process.parent < 0 { return false }
            current = process.parent
        }
        return false
    }
}
