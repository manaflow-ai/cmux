import Darwin

/// Who is on the other end of a loopback TCP connection to the proxy.
///
/// Chrome-style CEF never asks the embedder for proxy credentials, so the
/// proxy authenticates Chromium by process instead: the connection must come
/// from this app's own process or one of its child processes (the Chromium
/// helpers, whose network service opens every proxied connection). The
/// kernel knows which process owns the peer socket; another local user's or
/// app's process never matches. Same-user processes are otherwise equal on
/// macOS, so this is the strongest local boundary short of the socket not
/// existing (plans/cmux-next/remote-localhost.md section 5).
enum PeerProcess {
    /// True when a process in `candidates` (default: this process and its
    /// children) owns the TCP socket bound to 127.0.0.1:`peerPort` and
    /// connected to our port `localPort`.
    static func isTrusted(peerPort: UInt16, localPort: UInt16, candidates: [pid_t]? = nil) -> Bool {
        let pids = candidates ?? ([getpid()] + children(of: getpid()))
        return pids.contains { owns($0, localPort: peerPort, remotePort: localPort) }
    }

    static func children(of parent: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 256)
        let count = pids.withUnsafeMutableBytes { raw in
            proc_listchildpids(parent, raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    /// Whether `pid` has a TCP socket whose local port is `localPort` and
    /// whose remote port is `remotePort`.
    private static func owns(_ pid: pid_t, localPort: UInt16, remotePort: UInt16) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        let capacity = Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let used = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard used > 0 else { return false }
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp.tcpsi_ini
            // Ports are stored in network byte order in the low 16 bits.
            if UInt16(truncatingIfNeeded: tcp.insi_lport).byteSwapped == localPort,
               UInt16(truncatingIfNeeded: tcp.insi_fport).byteSwapped == remotePort {
                return true
            }
        }
        return false
    }
}
