import Darwin
import Foundation

/// Subprocess-free replacement for the `ps`/`lsof` helpers that PortScanner
/// previously shelled out to. Uses `sysctl(KERN_PROC_ALL)` for the process
/// table (pid, ppid, tty device) and `proc_pidinfo(PROC_PIDLISTFDS)` plus
/// `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` for each pid's listening TCP ports.
///
/// This exists because every `ps`/`lsof` exec is visible to macOS endpoint
/// security monitors (FortiDLP, CrowdStrike, etc.) which log every process
/// launch. The shell-kick + 2s agent rescan loop in PortScanner was spawning
/// thousands of short-lived subprocesses per day per workspace; libproc does
/// the same queries via syscall only.
enum ProcessScanner {
    /// Maps a comma-separated TTY name list (the same format `ps -t` accepts,
    /// e.g. `"ttys001,ttys003"`) to `[pid: tty_name]` for every process whose
    /// controlling terminal matches one of the listed names.
    static func pidsByTTY(ttyList: String) -> [Int: String] {
        let names = ttyList
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return [:] }

        var deviceToName: [Int64: String] = [:]
        for name in names {
            guard let dev = ttyDeviceID(forName: name) else { continue }
            deviceToName[dev] = name
        }
        guard !deviceToName.isEmpty else { return [:] }

        var mapping: [Int: String] = [:]
        forEachProcess { kinfo in
            let dev = Int64(kinfo.kp_eproc.e_tdev)
            guard dev > 0, let name = deviceToName[dev] else { return }
            let pid = Int(kinfo.kp_proc.p_pid)
            guard pid > 0 else { return }
            mapping[pid] = name
        }
        return mapping
    }

    /// Returns `[pid: ppid]` for every process in the system — the subprocess-
    /// free equivalent of `ps -ax -o pid=,ppid=`. Used to walk agent-owned
    /// descendant process trees.
    static func parentByPid() -> [Int: Int] {
        var mapping: [Int: Int] = [:]
        forEachProcess { kinfo in
            let pid = Int(kinfo.kp_proc.p_pid)
            let ppid = Int(kinfo.kp_eproc.e_ppid)
            guard pid > 0 else { return }
            mapping[pid] = ppid
        }
        return mapping
    }

    /// Returns `[pid: set<listening_tcp_port>]` — the subprocess-free
    /// equivalent of `lsof -nP -a -p <pids> -iTCP -sTCP:LISTEN -Fpn` filtered
    /// by the caller-supplied pid set.
    static func listeningTCPPorts(forPIDs pids: [Int]) -> [Int: Set<Int>] {
        var result: [Int: Set<Int>] = [:]
        for pid in pids where pid > 0 {
            let ports = listeningTCPPorts(forPID: pid)
            guard !ports.isEmpty else { continue }
            result[pid] = ports
        }
        return result
    }

    // MARK: - Internals

    private static func listeningTCPPorts(forPID pid: Int) -> Set<Int> {
        var bufferSize: Int32 = 0
        // First probe to size the fd list.
        let probe = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, nil, 0)
        guard probe > 0 else { return [] }
        bufferSize = probe

        let fdSize = Int32(MemoryLayout<proc_fdinfo>.stride)
        // Allocate with a little slack so FDs opened between the size probe
        // and the real call don't truncate us.
        let slack: Int32 = fdSize * 16
        let capacity = Int(bufferSize + slack)
        guard capacity >= Int(fdSize) else { return [] }

        let entryCount = capacity / Int(fdSize)
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: entryCount)
        let bytes = Int32(entryCount) * fdSize

        let written = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, buf.baseAddress, bytes)
        }
        guard written > 0 else { return [] }
        let count = Int(written) / Int(fdSize)

        var ports: Set<Int> = []
        for i in 0..<count {
            let fd = fds[i]
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            if let port = listenPort(forPID: pid, fd: fd.proc_fd) {
                ports.insert(port)
            }
        }
        return ports
    }

    private static func listenPort(forPID pid: Int, fd: Int32) -> Int? {
        var info = socket_fdinfo()
        let expected = Int32(MemoryLayout<socket_fdinfo>.stride)
        let written = proc_pidfdinfo(pid_t(pid), fd, PROC_PIDFDSOCKETINFO, &info, expected)
        guard written == expected else { return nil }

        let psi = info.psi
        guard Int(psi.soi_kind) == SOCKINFO_TCP else { return nil }
        guard psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { return nil }

        // insi_lport is stored in network byte order; convert to host order.
        let rawPort = psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
        let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: rawPort)))
        guard port > 0, port <= 65535 else { return nil }
        return port
    }

    /// Resolve a TTY *name* (as reported by `tty(1)` with `/dev/` stripped,
    /// e.g. `ttys001`) to the `st_rdev` device ID that `kinfo_proc.kp_eproc.e_tdev`
    /// stores. Returns nil for non-tty strings.
    private static func ttyDeviceID(forName name: String) -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "not a tty" else { return nil }

        let path = trimmed.hasPrefix("/dev/") ? trimmed : "/dev/\(trimmed)"
        var statInfo = stat()
        guard stat(path, &statInfo) == 0 else { return nil }
        return Int64(statInfo.st_rdev)
    }

    /// Enumerates every process on the system once via `sysctl(KERN_PROC_ALL)`
    /// and invokes `body` with each `kinfo_proc`. Retries on ENOMEM to handle
    /// the table growing between the size probe and the read.
    private static func forEachProcess(_ body: (kinfo_proc) -> Void) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride

        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
                return
            }

            let capacity = max(1, (length / stride) + 32)
            var processes = Array(repeating: kinfo_proc(), count: capacity)
            // sysctl uses `oldlenp` as both input (declared buffer size) and
            // output (bytes actually written). Declare the full allocation —
            // not the probed size — so the 32-entry slack absorbs process-
            // table growth between probe and read instead of triggering a
            // spurious ENOMEM.
            var bufferLength = capacity * stride
            let result = processes.withUnsafeMutableBufferPointer { buffer -> Int32 in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &bufferLength, nil, 0)
            }
            if result == 0 {
                let count = min(processes.count, bufferLength / stride)
                for i in 0..<count {
                    body(processes[i])
                }
                return
            }
            guard errno == ENOMEM else { return }
        }
    }
}
