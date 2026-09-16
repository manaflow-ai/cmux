public import Darwin

/// Keeps enumeration failures visible instead of silently dropping tree edges.
///
/// ```swift
/// let listing = DarwinProcessListing.capture()
/// if listing.isComplete { /* build an index from listing.processes */ }
/// ```
public struct DarwinProcessListing: Sendable {
    /// Unique readable process topology records, including public sysctl fallbacks.
    public let processes: [proc_bsdinfo]
    /// Whether enumeration finished without truncation or unreadable topology.
    public let isComplete: Bool
    /// Listed PIDs whose topology could not be read; excludes unknown truncated rows.
    public let missingProcessCount: Int

    /// Captures current process topology with at most three PID-buffer attempts.
    ///
    /// - Returns: The available records and explicit enumeration completeness.
    /// Run outside a UI actor; detailed memory measurements are a separate operation.
    public static func capture() -> Self {
        capture(listPIDs: proc_listallpids, readProcess: readBSDInfo)
    }

    static func capture(
        listPIDs: (UnsafeMutableRawPointer?, Int32) -> Int32,
        readProcess: (pid_t) -> proc_bsdinfo?
    ) -> Self {
        let initialCount = Int(listPIDs(nil, 0))
        guard initialCount > 0 else {
            return Self(processes: [], isComplete: false, missingProcessCount: 0)
        }
        // A bounded retry absorbs normal fork/exit churn. Exhausting it is an
        // incomplete sample, never evidence that the unseen subtree is empty.
        var capacity = initialCount + 32
        var lastPIDs: [pid_t] = []
        for _ in 0..<3 {
            guard capacity <= Int(Int32.max) / MemoryLayout<pid_t>.stride else { break }
            var pids = [pid_t](repeating: 0, count: capacity)
            let returned = pids.withUnsafeMutableBytes {
                listPIDs($0.baseAddress, Int32($0.count))
            }
            guard returned > 0 else { break }
            lastPIDs = Array(pids.prefix(min(Int(returned), capacity)))
            if Int(returned) < capacity {
                return resolve(lastPIDs, listingComplete: true, readProcess: readProcess)
            }
            capacity = max(capacity * 2, Int(returned) + 32)
        }
        return resolve(lastPIDs, listingComplete: false, readProcess: readProcess)
    }

    private static func resolve(
        _ pids: [pid_t],
        listingComplete: Bool,
        readProcess: (pid_t) -> proc_bsdinfo?
    ) -> Self {
        var processes: [proc_bsdinfo] = []
        var missingCount = 0
        var seen: Set<pid_t> = []
        for pid in pids where pid > 0 && seen.insert(pid).inserted {
            guard let info = readProcess(pid), info.pbi_pid == UInt32(pid) else {
                missingCount += 1
                continue
            }
            processes.append(info)
        }
        return Self(
            processes: processes,
            isComplete: listingComplete && missingCount == 0,
            missingProcessCount: missingCount
        )
    }

    private static func readBSDInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size { return info }
        // libproc denies detailed records for other users, even though the
        // public process topology is readable. Keep those parent edges so an
        // unrelated protected process does not disable descendant accounting.
        // Its memory remains unavailable unless the resource APIs can read it.
        return fallbackBSDInfo(pid)
    }
}
