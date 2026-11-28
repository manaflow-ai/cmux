#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

#if canImport(Darwin)
/// Reads the existing watcher's kernel identity; never guesses from a stale PID file.
struct AgentRestoreLeaseOwner {
    private let maximumDuration: TimeInterval = 1

    func liveProcessID(descriptor: Int32) -> Int32? {
        var file = stat()
        guard fstat(descriptor, &file) == 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + maximumDuration
        var pids = [Int32](repeating: 0, count: 8_192)
        let count = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return nil }
        for pid in pids.prefix(min(pids.count, Int(count) / MemoryLayout<Int32>.stride)) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            guard let watcher = process(pid), watcher.pbi_ppid > 1,
                  holdsLease(pid: pid, file: file),
                  watchedProcessID(pid: pid) == Int32(watcher.pbi_ppid),
                  let agent = process(Int32(watcher.pbi_ppid)),
                  let currentWatcher = process(pid), sameGeneration(watcher, currentWatcher),
                  currentWatcher.pbi_ppid == watcher.pbi_ppid,
                  holdsLease(pid: pid, file: file),
                  let currentAgent = process(Int32(watcher.pbi_ppid)),
                  sameGeneration(agent, currentAgent) else { continue }
            // The watcher keeps the lease on fd 3 and watches its launching
            // parent through exec. Parentage plus generation checks rule out
            // PID reuse while a dying watcher is waiting to be reaped.
            return Int32(watcher.pbi_ppid)
        }
        return nil
    }

    private func process(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard pid > 1,
              proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB) else { return nil }
        return info
    }

    private func sameGeneration(_ lhs: proc_bsdinfo, _ rhs: proc_bsdinfo) -> Bool {
        lhs.pbi_start_tvsec == rhs.pbi_start_tvsec && lhs.pbi_start_tvusec == rhs.pbi_start_tvusec
    }

    private func holdsLease(pid: Int32, file: stat) -> Bool {
        var vnode = vnode_fdinfo()
        let size = MemoryLayout<vnode_fdinfo>.stride
        return proc_pidfdinfo(pid, AgentRestoreLaunchLease.watcherLeaseDescriptor,
                             PROC_PIDFDVNODEINFO, &vnode, Int32(size)) == size
            && vnode.pvi.vi_stat.vst_dev == file.st_dev && vnode.pvi.vi_stat.vst_ino == file.st_ino
    }

    private func watchedProcessID(pid: Int32) -> Int32? {
        var path = [CChar](repeating: 0, count: 4_096)
        guard path.withUnsafeMutableBytes({ proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }) > 0,
              path.withUnsafeBufferPointer({ URL(fileURLWithPath: String(cString: $0.baseAddress!)).lastPathComponent }) == "cmux"
        else { return nil }
        // Read only argv from the kernel's bounded process-argument buffer.
        // Never expose or interpret the environment that follows it.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        var length = bytes.count
        let status = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &length, nil, 0) }
        guard status == 0, length > MemoryLayout<Int32>.size,
              bytes.withUnsafeBytes({ $0.loadUnaligned(as: Int32.self) }) == 3 else { return nil }
        var offset = MemoryLayout<Int32>.size
        while offset < length, bytes[offset] != 0 { offset += 1 }
        while offset < length, bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<3 {
            let start = offset
            while offset < length, bytes[offset] != 0 { offset += 1 }
            guard offset < length else { return nil }
            arguments.append(String(decoding: bytes[start..<offset], as: UTF8.self))
            offset += 1
        }
        guard arguments[1] == "__restore-lease-watch" else { return nil }
        return Int32(arguments[2])
    }
}
#else
/// Reads the existing watcher's kernel identity; never guesses from a stale PID file.
///
/// Linux reads the same facts from `/proc` (see `LinuxProcFS`): stat for
/// parentage, owner, zombie state and start time, `fd/3` for the lease inode,
/// `exe` and `cmdline` for the watcher's identity and argv.
struct AgentRestoreLeaseOwner {
    private let maximumDuration: TimeInterval = 1

    func liveProcessID(descriptor: Int32) -> Int32? {
        var file = stat()
        guard fstat(descriptor, &file) == 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + maximumDuration
        for pid in LinuxProcFS.userProcessIDs() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            guard let watcher = process(pid), watcher.parentProcessID > 1,
                  holdsLease(pid: pid, file: file),
                  watchedProcessID(pid: pid) == watcher.parentProcessID,
                  let agent = process(watcher.parentProcessID),
                  let currentWatcher = process(pid), currentWatcher.startTicks == watcher.startTicks,
                  currentWatcher.parentProcessID == watcher.parentProcessID,
                  holdsLease(pid: pid, file: file),
                  let currentAgent = process(watcher.parentProcessID),
                  currentAgent.startTicks == agent.startTicks else { continue }
            return watcher.parentProcessID
        }
        return nil
    }

    private func process(_ pid: Int32) -> LinuxProcessSnapshot? {
        guard pid > 1, let info = LinuxProcFS.snapshot(pid),
              info.userID == getuid(), !info.isZombie else { return nil }
        return info
    }

    private func holdsLease(pid: Int32, file: stat) -> Bool {
        guard let held = LinuxProcFS.descriptorFile(pid, AgentRestoreLaunchLease.watcherLeaseDescriptor) else { return false }
        return held.device == UInt64(file.st_dev) && held.inode == UInt64(file.st_ino)
    }

    private func watchedProcessID(pid: Int32) -> Int32? {
        guard let path = LinuxProcFS.executablePath(pid),
              URL(fileURLWithPath: path).lastPathComponent == "cmux",
              let arguments = LinuxProcFS.arguments(pid), arguments.count == 3,
              arguments[1] == "__restore-lease-watch" else { return nil }
        return Int32(arguments[2])
    }
}
#endif
