import Darwin
import Network
import CmuxNextCompat

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
    /// children) owns the exact established TCP peer identified by its full
    /// four-tuple. Ports alone are insufficient because 127/8 has many source
    /// addresses and a different process can bind the same port on another.
    static func isTrusted(
        peerHost: NWEndpoint.Host,
        peerPort: UInt16,
        localHost: NWEndpoint.Host,
        localPort: UInt16,
        candidates: [pid_t]? = nil
    ) -> Bool {
        guard let peerAddress = address(peerHost), let localAddress = address(localHost) else {
            return false
        }
        let pids = candidates ?? ([getpid()] + children(of: getpid()))
        return pids.contains {
            owns(
                $0,
                localAddress: peerAddress,
                localPort: peerPort,
                remoteAddress: localAddress,
                remotePort: localPort
            )
        }
    }

    static func children(of parent: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 256)
        let count = pids.withUnsafeMutableBytes { raw in
            proc_listchildpids(parent, raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    private enum Address: Equatable {
        case v4([UInt8])
        case v6([UInt8])
    }

    private static func address(_ host: NWEndpoint.Host) -> Address? {
        switch host {
        case .ipv4(let address): .v4(Array(address.rawValue))
        case .ipv6(let address): .v6(Array(address.rawValue))
        case .name(let name, _): name == "127.0.0.1" ? .v4([127, 0, 0, 1]) : nil
        @unknown default: nil
        }
    }

    /// Whether `pid` owns this exact established TCP four-tuple.
    private static func owns(
        _ pid: pid_t,
        localAddress: Address,
        localPort: UInt16,
        remoteAddress: Address,
        remotePort: UInt16
    ) -> Bool {
        let bytes = blockingProcPidInfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        let capacity = Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let used = fds.withUnsafeMutableBytes { raw in
            blockingProcPidInfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard used > 0 else { return false }
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcpInfo = info.psi.soi_proto.pri_tcp
            guard tcpInfo.tcpsi_state == Int32(TSI_S_ESTABLISHED) else { continue }
            let tcp = tcpInfo.tcpsi_ini
            // Ports are stored in network byte order in the low 16 bits.
            if UInt16(truncatingIfNeeded: tcp.insi_lport).byteSwapped == localPort,
               UInt16(truncatingIfNeeded: tcp.insi_fport).byteSwapped == remotePort,
               socketAddress(tcp, local: true) == localAddress,
               socketAddress(tcp, local: false) == remoteAddress {
                return true
            }
        }
        return false
    }

    private static func socketAddress(_ socket: in_sockinfo, local: Bool) -> Address? {
        if socket.insi_vflag & UInt8(clamping: INI_IPV4) != 0 {
            if local {
                var raw = socket.insi_laddr.ina_46.i46a_addr4
                return .v4(withUnsafeBytes(of: &raw) { Array($0) })
            }
            var raw = socket.insi_faddr.ina_46.i46a_addr4
            return .v4(withUnsafeBytes(of: &raw) { Array($0) })
        }
        if socket.insi_vflag & UInt8(clamping: INI_IPV6) != 0 {
            if local {
                var raw = socket.insi_laddr.ina_6
                return .v6(withUnsafeBytes(of: &raw) { Array($0) })
            }
            var raw = socket.insi_faddr.ina_6
            return .v6(withUnsafeBytes(of: &raw) { Array($0) })
        }
        return nil
    }
}
