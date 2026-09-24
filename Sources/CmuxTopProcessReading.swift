import CmuxFoundation
import Darwin

/// Native process reads, injected so census/enrichment costs and PID races can be exercised.
protocol CmuxTopProcessReading: Sendable {
    func enumerate() -> DarwinProcessListing
    func taskInfo(for pid: Int) -> proc_taskinfo?
    func resourceUsage(for pid: Int) -> rusage_info_v4?
    func processName(pid: Int, fallback: String) -> String
    func processPath(pid: Int) -> String?
    func scope(for pid: Int, key: CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScope?
    func matches(pid: Int, key: CmuxTopProcessScopeCacheKey) -> Bool
}
