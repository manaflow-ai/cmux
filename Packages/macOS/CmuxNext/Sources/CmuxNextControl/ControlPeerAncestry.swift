import CmuxNextCompat
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Whether a socket peer was started inside this cmux: it descends from the
/// app, or from a process running a trusted executable (the bundled cmux
/// binary). Terminals descend from the cmux-tui terminal hosts, which are
/// not the app's children and outlive it, so the app pid alone admits none.
///
/// The walk is the same on every platform; only ``lookup`` differs: `sysctl` and
/// `proc_pidpath` on Darwin, procfs on Linux (``procfs(root:)``), as Chromium reads
/// a process's parent from `/proc/<pid>/stat` (base/process/process_handle_linux.cc,
/// `GetParentProcessId`) and its executable from `/proc/<pid>/exe`
/// (base/process/process_handle_linux.cc, `GetProcessExecutablePath`).
struct ControlPeerAncestry: Sendable {
    /// Parent pid and executable path of a process; nil when it is gone.
    var lookup: @Sendable (pid_t) -> (parent: pid_t, executable: String?)?

    #if canImport(Darwin)
    static let system = ControlPeerAncestry { pid in
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        // SAFETY: sysctl reads the 4 names of `mib` and writes at most `size` bytes (one kinfo_proc) into `info`
        // and the size it wrote into `size`; all three are locals live for the call.
        guard unsafe sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(clamping: MAXPATHLEN) * 4)
        // SAFETY: proc_pidpath writes at most buffer.count bytes into the array's own storage, lent for the call.
        let length = unsafe proc_pidpath(pid, &buffer, UInt32(clamping: buffer.count))
        let path = length > 0 ? String(decoding: buffer.prefix(Int(clamping: length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        return (info.kp_eproc.e_ppid, path)
    }
    #else
    static let system = procfs(root: "/proc")
    #endif

    /// The ancestry procfs at `root` describes: a process's parent is field 4 of `<root>/<pid>/stat`, its
    /// executable the target of `<root>/<pid>/exe` (the kernel's real path; a replaced binary reads
    /// `<path> (deleted)`, which matches no trusted executable). A process whose `stat` cannot be read or
    /// parsed is gone. Plain files and links, so tests build a fake tree on any platform.
    static func procfs(root: String) -> ControlPeerAncestry {
        ControlPeerAncestry { pid in
            guard pid > 0, let line = readPrefix("\(root)/\(pid)/stat", limit: 512),
                  let parent = parentPID(stat: line) else { return nil }
            return (parent, linkTarget("\(root)/\(pid)/exe"))
        }
    }

    /// The parent pid in one `/proc/<pid>/stat` line, `pid (comm) state ppid ...` (proc(5)). The command name
    /// may hold spaces and `)`, so the fields after it start after the line's last `)`. Nil for anything else.
    static func parentPID(stat: [UInt8]) -> pid_t? {
        guard let close = stat.lastIndex(of: UInt8(ascii: ")")) else { return nil }
        let fields = stat.suffix(from: stat.index(after: close)).split(separator: UInt8(ascii: " "), omittingEmptySubsequences: true)
        guard fields.count >= 2, fields[0].count == 1,
              let parent = pid_t(String(decoding: fields[1], as: UTF8.self)), parent >= 0 else { return nil }
        return parent
    }

    /// Up to `limit` bytes from the start of the file at `path`, in one read (procfs makes a `stat` line whole
    /// on its first read); nil when it cannot be opened or read, which denies the peer.
    private static func readPrefix(_ path: String, limit: Int) -> [UInt8]? {
        blockingCall(.fileIO) {
            // SAFETY: open reads the NUL-terminated copy of the path made for the call.
            let descriptor = unsafe open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var buffer = [UInt8](repeating: 0, count: limit)
            // SAFETY: read writes at most `limit` bytes, the array's size, into its own storage, lent for the call.
            let count = unsafe read(descriptor, &buffer, limit)
            return count >= 0 ? Array(buffer.prefix(count)) : nil
        }
    }

    /// The target of the symbolic link at `path`; nil when there is none.
    private static func linkTarget(_ path: String) -> String? {
        blockingCall(.fileIO) {
            var buffer = [CChar](repeating: 0, count: Int(truncatingIfNeeded: PATH_MAX) + 1)
            // SAFETY: readlink writes at most buffer.count - 1 bytes into the array's own storage, lent for the call.
            let length = unsafe readlink(path, &buffer, buffer.count - 1)
            guard length > 0 else { return nil }
            return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    func isInside(_ pid: pid_t, ancestor: pid_t, executables: Set<String>) -> Bool {
        var current = pid
        for _ in 0..<128 {
            if current == ancestor { return true }
            if current <= 1 { return false }
            guard let process = lookup(current) else { return false }
            // A caller does not become trusted merely by executing the public
            // bundled CLI itself. Only an earlier process in its ancestry can
            // establish that the caller was started inside this cmux.
            if current != pid, let path = process.executable, executables.contains(path) {
                return true
            }
            if process.parent == current || process.parent < 0 { return false }
            current = process.parent
        }
        return false
    }
}
