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
        // No cross-census scope cache: exec can change argv/environment without
        // changing the PID's birth timestamp. In particular, absence cannot be
        // cached across authoritative restore scans.
        guard case .resolved(let value) = CmuxTopProcessSnapshot.cmuxScopeProbe(
            for: pid, expectedCacheKey: key
        ) else { return nil }
        return value
    }
    func matches(pid: Int, key: CmuxTopProcessScopeCacheKey) -> Bool {
        CmuxTopProcessSnapshot.processMatchesKey(pid, key)
    }
}
