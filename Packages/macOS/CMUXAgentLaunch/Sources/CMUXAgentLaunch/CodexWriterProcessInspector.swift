import Darwin
import Foundation

/// Finds diagnostic candidates for a held lock without granting process-control authority.
public struct CodexWriterProcessInspector: Sendable {
    /// An observed process with the exact lock inode open, not proof it holds flock.
    public struct Candidate: Equatable, Sendable {
        /// Observed process identifier, for diagnosis only.
        public let processID: Int32
        /// Executable basename with terminal control characters removed.
        public let name: String
    }

    private let processIDs: @Sendable () -> [Int32]
    private let uptime: @Sendable () -> TimeInterval
    private let maximumDuration: TimeInterval

    /// Creates a read-only inspector with the system census and a two-second budget.
    public init() {
        self.init(processIDs: { Self.userProcessIDs() })
    }

    /// Creates a bounded, read-only process inspector with injected discovery.
    /// - Parameters:
    ///   - processIDs: Process census; tests can restrict discovery to fixture processes.
    ///   - uptime: Monotonic time source, injected to make deadline tests deterministic.
    ///   - maximumDuration: Discovery budget in seconds; production defaults to two.
    public init(
        processIDs: @escaping @Sendable () -> [Int32],
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        maximumDuration: TimeInterval = 2
    ) {
        self.processIDs = processIDs
        self.uptime = uptime
        self.maximumDuration = maximumDuration
    }

    /// Observes candidate PIDs without reading command arguments or environments.
    /// - Parameter inspection: A held writer-lock observation.
    /// - Returns: Best-effort candidates; an empty list means the owner is unknown.
    public func candidates(for inspection: CodexWriterLockInspection) -> [Candidate] {
        guard inspection.state == .active, let device = inspection.device,
              let inode = inspection.inode else { return [] }
        let deadline = uptime() + maximumDuration
        var candidates: [Candidate] = []
        for pid in processIDs().prefix(8192) where pid > 0 {
            guard !Task.isCancelled, uptime() < deadline else { break }
            guard let before = process(pid), holds(device: device, inode: inode, pid: pid, deadline: deadline) else { continue }
            var path = [CChar](repeating: 0, count: 4096)
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0, let after = process(pid),
                  before.pbi_start_tvsec == after.pbi_start_tvsec,
                  before.pbi_start_tvusec == after.pbi_start_tvusec else { continue }
            let rawName = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let safeName = String((rawName as NSString).lastPathComponent.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || " ._-".unicodeScalars.contains($0)
            })
            candidates.append(Candidate(processID: pid, name: safeName))
        }
        let current = CodexWriterLockInspector().inspect(sessionID: URL(fileURLWithPath: inspection.lockPath)
            .deletingPathExtension().lastPathComponent, codexHome: inspection.codexHome)
        guard current.state == .active, current.deviceAndInodeMatch(inspection) else { return [] }
        return candidates.sorted { $0.processID < $1.processID }
    }

    private func process(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        // A successfully inspected zombie is gone, irrespective of stale errno.
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB) else { return nil }
        return info
    }

    private func holds(device: Int32, inode: UInt64, pid: Int32, deadline: TimeInterval) -> Bool {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0, Int(bytes) <= 4096 * stride else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 64)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return false }
        for fd in fds.prefix(min(fds.count, Int(used) / stride)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            guard !Task.isCancelled, uptime() < deadline else { return false }
            var vnode = vnode_fdinfo()
            let size = MemoryLayout<vnode_fdinfo>.stride
            if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &vnode, Int32(size)) == size,
               vnode.pvi.vi_stat.vst_dev == device, vnode.pvi.vi_stat.vst_ino == inode { return true }
        }
        return false
    }

    private static func userProcessIDs() -> [Int32] {
        var pids = [Int32](repeating: 0, count: 8192)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
        }
        return bytes > 0 ? Array(pids.prefix(min(pids.count, Int(bytes) / MemoryLayout<Int32>.stride))) : []
    }
}
