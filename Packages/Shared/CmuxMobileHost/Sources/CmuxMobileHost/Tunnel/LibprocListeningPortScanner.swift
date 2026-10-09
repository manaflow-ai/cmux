#if os(macOS)
import Darwin

/// `ListeningPortScanner` over libproc: the socket table of each given pid
/// (`PROC_PIDLISTFDS`, then `PROC_PIDFDSOCKETINFO`), TCP sockets in LISTEN
/// bound to a wildcard or loopback address. No process is spawned; only the
/// current user's processes are readable, which is all a workspace runs.
public struct LibprocListeningPortScanner: ListeningPortScanner {
    public let maximumDescriptorsPerProcess: Int

    public init(maximumDescriptorsPerProcess: Int = 4096) {
        self.maximumDescriptorsPerProcess = maximumDescriptorsPerProcess
    }

    public func listeningPorts(of pids: [Int32]) -> [Int32: [UInt16]] {
        var result: [Int32: [UInt16]] = [:]
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: maximumDescriptorsPerProcess)
        let stride = MemoryLayout<proc_fdinfo>.stride
        for pid in Set(pids) where pid > 0 {
            let bytes = descriptors.withUnsafeMutableBytes { buffer in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
            }
            guard bytes > 0 else { continue }
            var ports: Set<UInt16> = []
            for descriptor in descriptors.prefix(min(Int(bytes) / stride, maximumDescriptorsPerProcess))
            where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                if let port = Self.loopbackListener(pid: pid, fd: descriptor.proc_fd) { ports.insert(port) }
            }
            if !ports.isEmpty { result[pid] = ports.sorted() }
        }
        return result
    }

    private static func loopbackListener(pid: Int32, fd: Int32) -> UInt16? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
              info.psi.soi_kind == Int32(SOCKINFO_TCP) else { return nil }
        let tcp = info.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { return nil }
        let inet = tcp.tcpsi_ini
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport))
        if inet.insi_vflag & UInt8(INI_IPV4) != 0 {
            var address = inet.insi_laddr.ina_46.i46a_addr4
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            return bytes == [0, 0, 0, 0] || bytes.first == 127 ? port : nil
        }
        if inet.insi_vflag & UInt8(INI_IPV6) != 0 {
            var address = inet.insi_laddr.ina_6
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            return bytes.allSatisfy { $0 == 0 } || loopback ? port : nil
        }
        return nil
    }
}
#endif
