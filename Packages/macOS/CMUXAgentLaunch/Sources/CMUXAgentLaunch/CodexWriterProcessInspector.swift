import Darwin
import Foundation

/// Supplies best-effort diagnostics for an active writer lock, never signal authority.
public struct CodexWriterProcessInspector: Sendable {
    /// A process observed with the exact locked inode open.
    ///
    /// An open descriptor is not proof of flock ownership. Diagnostics label
    /// these as candidates; callers must never kill or focus based on this value.
    public struct Candidate: Equatable, Sendable {
        /// The observed PID.
        public let pid: Int32
        /// Executable basename, with terminal control characters removed.
        public let executable: String
    }

    /// Creates a read-only kernel process inspector.
    public init() {}

    /// Lists candidates from the current user's processes, bounded to two seconds.
    /// - Parameter inspection: An active lock observation with a device and inode.
    /// - Returns: Available evidence; an empty list means the owner is unknown.
    public func candidates(for inspection: CodexWriterLockInspection) -> [Candidate] {
        guard inspection.state == .active, let device = inspection.device,
              let inode = inspection.inode else { return [] }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var pids = [Int32](repeating: 0, count: 8192)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return [] }
        var result: [Candidate] = []
        for pid in pids.prefix(Int(bytes) / MemoryLayout<Int32>.stride) where pid > 0 && pid != getpid() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            var before = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.stride
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, Int32(size)) == size else { continue }
            let count = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard count > 0, count <= 4096 * MemoryLayout<proc_fdinfo>.stride else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(count) / MemoryLayout<proc_fdinfo>.stride + 64)
            let used = fds.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            guard used > 0 else { continue }
            let matches = fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride).contains { fd in
                guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE),
                      ProcessInfo.processInfo.systemUptime < deadline else { return false }
                var vnode = vnode_fdinfo()
                let size = MemoryLayout<vnode_fdinfo>.stride
                return proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &vnode, Int32(size)) == size
                    && vnode.pvi.vi_stat.vst_dev == device && vnode.pvi.vi_stat.vst_ino == inode
            }
            var after = proc_bsdinfo()
            guard matches,
                  proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, Int32(size)) == size,
                  before.pbi_start_tvsec == after.pbi_start_tvsec,
                  before.pbi_start_tvusec == after.pbi_start_tvusec else { continue }
            var path = [CChar](repeating: 0, count: 4096)
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0 else { continue }
            let name = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let basename = (name as NSString).lastPathComponent
            let safeName = String(basename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            result.append(Candidate(pid: pid, executable: safeName))
        }
        return result.sorted { $0.pid < $1.pid }
    }
}
