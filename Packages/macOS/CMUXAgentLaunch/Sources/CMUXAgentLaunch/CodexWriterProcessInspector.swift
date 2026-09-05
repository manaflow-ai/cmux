import Darwin
import Foundation

/// Reads live descriptor and process identity evidence for a locked Codex thread.
/// Keep this bounded I/O off the UI actor; it is also used by the synchronous CLI.
public struct CodexWriterProcessInspector: Sendable {
    /// Creates a stateless process inspector.
    public init() {}

    /// Finds current holders of the exact lock inode without reading process environments.
    ///
    /// - Parameter inspection: An active lock probe with a verified device/inode.
    /// - Returns: Holder generations plus completeness; an incomplete scan cannot authorize focus.
    public func owners(for inspection: CodexWriterLockInspection) -> CodexWriterOwnerScan {
        guard inspection.state == .active else { return CodexWriterOwnerScan(owners: [], isComplete: true) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var pids = [Int32](repeating: 0, count: 8192)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count)) }
        let count = Int(bytes) / MemoryLayout<Int32>.stride
        guard count > 0, count < pids.count else { return CodexWriterOwnerScan(owners: [], isComplete: false) }
        var owners: [CodexWriterOwner] = []
        var complete = true
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                return CodexWriterOwnerScan(owners: owners, isComplete: false)
            }
            guard let info = process(pid) else {
                if errno == ESRCH { continue }
                complete = false
                continue
            }
            guard info.pbi_uid == getuid() else { continue }
            guard let holdsLock = holds(inspection, pid: pid) else { complete = false; continue }
            guard holdsLock else { continue }
            guard let owner = owner(pid: pid, info: info), isCurrent(owner, inspection: inspection) else {
                complete = false
                continue
            }
            owners.append(owner)
        }
        return CodexWriterOwnerScan(owners: owners, isComplete: complete)
    }

    /// Revalidates a holder's generation and exact descriptor before navigation.
    ///
    /// - Parameters:
    ///   - owner: Previously observed holder.
    ///   - inspection: Lock inode from the corresponding active probe.
    /// - Returns: Whether the same live generation still opens that inode.
    public func isCurrent(_ owner: CodexWriterOwner, inspection: CodexWriterLockInspection) -> Bool {
        guard let info = process(owner.pid), info.pbi_start_tvsec == owner.startSeconds,
              info.pbi_start_tvusec == owner.startMicroseconds,
              owner.ttyDevice == ttyDevice(info) else { return false }
        return holds(inspection, pid: owner.pid) == true
    }

    /// Checks that a current foreground runtime is in the holder's live ancestry.
    /// - Parameters:
    ///   - owner: The holder whose ancestry must still agree.
    ///   - foregroundPID: PID read directly from the surface's current Ghostty runtime.
    /// - Returns: Whether this runtime can safely receive continuation focus.
    public func descendsFromForeground(_ owner: CodexWriterOwner, foregroundPID: Int) -> Bool {
        guard foregroundPID > 0, foregroundPID <= Int(Int32.max),
              let info = process(owner.pid), info.pbi_start_tvsec == owner.startSeconds,
              info.pbi_start_tvusec == owner.startMicroseconds else { return false }
        return ancestors(pid: owner.pid).contains(Int32(foregroundPID))
    }

    private func process(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_status != UInt32(SZOMB) else { return nil }
        return info
    }

    private func holds(_ inspection: CodexWriterLockInspection, pid: Int32) -> Bool? {
        guard let device = inspection.device, let inode = inspection.inode else { return nil }
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0, bytes <= 4096 * MemoryLayout<proc_fdinfo>.stride else { return errno == ESRCH ? false : nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 64)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0, used < fds.count * MemoryLayout<proc_fdinfo>.stride else { return errno == ESRCH ? false : nil }
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfo()
            let size = MemoryLayout<vnode_fdinfo>.stride
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &vnode, Int32(size)) == size else {
                if errno == EBADF || errno == ESRCH { continue }
                return nil
            }
            if vnode.pvi.vi_stat.vst_dev == device, vnode.pvi.vi_stat.vst_ino == inode { return true }
        }
        return false
    }

    private func owner(pid: Int32, info: proc_bsdinfo) -> CodexWriterOwner? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        let executable = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var cwdInfo = proc_vnodepathinfo()
        let cwdSize = MemoryLayout<proc_vnodepathinfo>.stride
        let cwd: String? = if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwdInfo, Int32(cwdSize)) == cwdSize {
            withUnsafeBytes(of: cwdInfo.pvi_cdir.vip_path) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
        } else { nil }
        return CodexWriterOwner(
            pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
            executable: executable, workingDirectory: cwd, ttyDevice: ttyDevice(info), ancestorPIDs: ancestors(pid: pid)
        )
    }

    private func ttyDevice(_ info: proc_bsdinfo) -> Int64? {
        let device = Int64(info.e_tdev)
        return device > 0 && device != Int64(UInt32.max) ? device : nil
    }

    private func ancestors(pid: Int32) -> Set<Int32> {
        var result: Set<Int32> = []
        var next = pid
        for _ in 0..<64 {
            guard next > 1, result.insert(next).inserted, let info = process(next) else { break }
            next = Int32(info.pbi_ppid)
        }
        return result
    }
}
