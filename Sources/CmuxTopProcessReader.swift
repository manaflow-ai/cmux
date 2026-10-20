import CmuxCore
import CmuxFoundation
import Darwin

/// Darwin reader for the current process's fixed host and effective user scope.
struct CmuxTopProcessReader: CmuxTopProcessReading {
    func enumerate() -> DarwinProcessListing { DarwinProcessEnumerator().capture() }
    func taskInfo(for pid: Int) -> proc_taskinfo? { CmuxTopProcessSnapshot.taskInfo(for: pid) }
    func resourceUsage(for pid: Int) -> rusage_info_v4? { CmuxTopProcessSnapshot.resourceUsage(for: pid) }
    func processName(pid: Int, fallback: String) -> String {
        CmuxTopProcessSnapshot.processName(pid: pid, fallback: fallback)
    }
    func processPath(pid: Int) -> String? { CmuxTopProcessSnapshot.processPath(pid: pid) }
    func scope(for pid: Int, key: CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScope? {
        // Exec can change argv/environment without changing the PID's birth
        // timestamp, so this reads every time. Reuse across censuses is keyed by
        // `execIdentity` (CmuxTopProcessEnrichmentMemo), which an exec changes.
        guard case .resolved(let value) = CmuxTopProcessSnapshot.cmuxScopeProbe(
            for: pid, expectedCacheKey: key
        ) else { return nil }
        return value
    }
    func matches(pid: Int, key: CmuxTopProcessScopeCacheKey) -> Bool {
        CmuxTopProcessSnapshot.processMatchesKey(pid, key)
    }
    func execIdentity(pid: Int) -> CmuxTopProcessExecIdentity? { CmuxTopProcessExecIdentity.read(pid: pid) }
    func processHasExited(pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        return PIDPresence.current(pid: pid_t(pid)) == .absent
    }
}
