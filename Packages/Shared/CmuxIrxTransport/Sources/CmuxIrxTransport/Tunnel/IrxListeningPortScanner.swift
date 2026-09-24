import Darwin
import Foundation

/// Lists this Mac's TCP listeners that loopback can reach, natively through
/// `libproc` (the same per-process socket table `lsof` reads), without
/// spawning a process. Only processes of the current user are visible, which
/// covers the dev servers a browser tunnel is for.
///
/// Bounded work: at most `maximumProcesses` processes and
/// `maximumDescriptorsPerProcess` descriptors each are inspected, and at most
/// `maximumPorts` ports are returned.
public enum IrxListeningPortScanner {
    public static let maximumProcesses = 8_192
    public static let maximumDescriptorsPerProcess = 4_096
    public static let maximumPorts = 1_024

    /// One listening socket as the kernel reports it.
    public struct Listener: Equatable, Sendable {
        public var port: Int
        /// The bound local address (`0.0.0.0`/`::` for a wildcard).
        public var address: IrxTunnelIPAddress
        /// An IPv6 socket that does not accept IPv4.
        public var ipv6Only: Bool

        public init(port: Int, address: IrxTunnelIPAddress, ipv6Only: Bool) {
            self.port = port
            self.address = address
            self.ipv6Only = ipv6Only
        }
    }

    /// The loopback-reachable listening ports, one entry per port (IPv4
    /// preferred when a port listens on both), sorted by port.
    public static func loopbackListeningPorts() -> [IrxListeningPort] {
        #if os(macOS)
        return reachableFromLoopback(listeners())
        #else
        return []
        #endif
    }

    /// Maps raw listeners to connect targets: loopback-bound sockets keep
    /// their address, wildcards are reached via loopback, and sockets bound
    /// to another interface address are skipped (loopback cannot reach them).
    public static func reachableFromLoopback(_ listeners: [Listener]) -> [IrxListeningPort] {
        var byPort: [Int: String] = [:]
        for listener in listeners where (1...65_535).contains(listener.port) {
            let target: String?
            switch listener.address {
            case .v4([0, 0, 0, 0]):
                target = "127.0.0.1"
            case .v4(let bytes) where bytes[0] == 127:
                target = listener.address.text
            case .v6(let bytes) where bytes.allSatisfy({ $0 == 0 }):
                target = listener.ipv6Only ? "::1" : "127.0.0.1"
            case .v6 where listener.address == .loopbackV6:
                target = "::1"
            default:
                target = nil
            }
            guard let target else { continue }
            if byPort[listener.port] == nil || target != "::1" {
                byPort[listener.port] = target
            }
        }
        return byPort.keys.sorted().prefix(maximumPorts).map { IrxListeningPort(port: $0, address: byPort[$0]!) }
    }

    #if os(macOS)
    static func listeners() -> [Listener] {
        var pids = [pid_t](repeating: 0, count: maximumProcesses)
        let pidBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard pidBytes > 0 else { return [] }
        let pidCount = min(Int(pidBytes), maximumProcesses)
        var result: [Listener] = []
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: maximumDescriptorsPerProcess)
        let descriptorStride = MemoryLayout<proc_fdinfo>.stride
        for pid in pids.prefix(pidCount) where pid > 0 {
            let bytes = descriptors.withUnsafeMutableBytes { buffer in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
            }
            guard bytes > 0 else { continue }
            let count = min(Int(bytes) / descriptorStride, maximumDescriptorsPerProcess)
            for descriptor in descriptors.prefix(count) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                if let listener = listener(pid: pid, fd: descriptor.proc_fd) {
                    result.append(listener)
                }
            }
        }
        return result
    }

    private static func listener(pid: pid_t, fd: Int32) -> Listener? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        guard info.psi.soi_kind == Int32(SOCKINFO_TCP) else { return nil }
        let tcp = info.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { return nil }
        let inet = tcp.tcpsi_ini
        let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)))
        if inet.insi_vflag & UInt8(INI_IPV4) != 0 {
            var address = inet.insi_laddr.ina_46.i46a_addr4
            return Listener(port: port, address: .v4(withUnsafeBytes(of: &address) { Array($0) }), ipv6Only: false)
        }
        if inet.insi_vflag & UInt8(INI_IPV6) != 0 {
            var address = inet.insi_laddr.ina_6
            // A dual-stack wildcard socket carries both flags; the IPv4 check
            // above already mapped it. IPv6-only here.
            return Listener(port: port, address: .v6(withUnsafeBytes(of: &address) { Array($0) }), ipv6Only: true)
        }
        return nil
    }
    #endif
}
