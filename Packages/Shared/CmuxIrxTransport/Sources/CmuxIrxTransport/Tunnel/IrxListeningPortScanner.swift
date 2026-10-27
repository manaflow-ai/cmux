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
public struct IrxListeningPortScanner: Sendable {
    public let maximumProcesses: Int
    public let maximumDescriptorsPerProcess: Int
    public let maximumPorts: Int

    /// - Parameters:
    ///   - maximumProcesses: Processes inspected at most.
    ///   - maximumDescriptorsPerProcess: Descriptors inspected per process at most.
    ///   - maximumPorts: Ports returned at most.
    public init(maximumProcesses: Int = 8_192, maximumDescriptorsPerProcess: Int = 4_096, maximumPorts: Int = 1_024) {
        self.maximumProcesses = maximumProcesses
        self.maximumDescriptorsPerProcess = maximumDescriptorsPerProcess
        self.maximumPorts = maximumPorts
    }

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
    public func loopbackListeningPorts() -> [IrxListeningPort] {
        #if os(macOS)
        return reachableFromLoopback(listeners())
        #else
        return []
        #endif
    }

    /// Maps raw listeners to connect targets: loopback-bound sockets keep
    /// their address, wildcards are reached via loopback, and sockets bound
    /// to another interface address are skipped (loopback cannot reach them).
    public func reachableFromLoopback(_ listeners: [Listener]) -> [IrxListeningPort] {
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
        return byPort.sorted { $0.key < $1.key }.prefix(maximumPorts).map { IrxListeningPort(port: $0.key, address: $0.value) }
    }

    #if os(macOS)
    func listeners() -> [Listener] {
        guard maximumProcesses > 0, maximumDescriptorsPerProcess > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: maximumProcesses)
        let pidBufferSize = Int32(clamping: pids.count * MemoryLayout<pid_t>.stride)
        // SAFETY: proc_listallpids writes at most pidBufferSize bytes, the array's byte
        // size (clamping can only shrink it), into its storage, live for this call.
        let pidBytes = unsafe proc_listallpids(&pids, pidBufferSize)
        guard pidBytes > 0 else { return [] }
        let pidCount = min(Int(clamping: pidBytes), maximumProcesses)
        var result: [Listener] = []
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: maximumDescriptorsPerProcess)
        let descriptorStride = MemoryLayout<proc_fdinfo>.stride
        let descriptorBufferSize = Int32(clamping: descriptors.count * descriptorStride)
        for pid in pids.prefix(pidCount) where pid > 0 {
            // SAFETY: proc_pidinfo writes at most descriptorBufferSize bytes, the array's
            // byte size (clamping can only shrink it), into its storage, live for this call.
            let bytes = unsafe proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, descriptorBufferSize)
            guard bytes > 0 else { continue }
            let count = min(Int(clamping: bytes) / descriptorStride, maximumDescriptorsPerProcess)
            for descriptor in descriptors.prefix(count) where descriptor.proc_fdtype == UInt32(clamping: PROX_FDTYPE_SOCKET) {
                if let listener = Self.listener(pid: pid, fd: descriptor.proc_fd) {
                    result.append(listener)
                }
            }
        }
        return result
    }

    private static func listener(pid: pid_t, fd: Int32) -> Listener? {
        var info = socket_fdinfo()
        let size = Int32(clamping: MemoryLayout<socket_fdinfo>.size)
        // SAFETY: proc_pidfdinfo writes at most `size` bytes, MemoryLayout<socket_fdinfo>.size,
        // into the local `info`, live for this call.
        guard unsafe proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        guard info.psi.soi_kind == Int32(clamping: SOCKINFO_TCP) else { return nil }
        let tcp = info.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == Int32(clamping: TSI_S_LISTEN) else { return nil }
        let inet = tcp.tcpsi_ini
        let port = Int(clamping: UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)))
        if inet.insi_vflag & UInt8(clamping: INI_IPV4) != 0 {
            let address = IrxTunnelIPAddress(kernel: inet.insi_laddr.ina_46.i46a_addr4)
            return Listener(port: port, address: address, ipv6Only: false)
        }
        if inet.insi_vflag & UInt8(clamping: INI_IPV6) != 0 {
            // A dual-stack wildcard socket carries both flags; the IPv4 check
            // above already mapped it. IPv6-only here.
            let address = IrxTunnelIPAddress(kernel: inet.insi_laddr.ina_6)
            return Listener(port: port, address: address, ipv6Only: true)
        }
        return nil
    }
    #endif
}
