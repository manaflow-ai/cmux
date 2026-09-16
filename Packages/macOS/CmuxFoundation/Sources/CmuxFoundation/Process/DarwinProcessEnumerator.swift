import Darwin

/// Owns the process-enumeration dependencies for one synchronous sampling operation.
public struct DarwinProcessEnumerator {
    private let listPIDs: (UnsafeMutableRawPointer?, Int32) -> Int32
    private let readProcess: (pid_t) -> proc_bsdinfo?

    /// Creates an enumerator backed by Darwin's PID and public topology APIs.
    public init() {
        let reader = DarwinProcessInfoReader()
        self.init(listPIDs: proc_listallpids, readProcess: reader.readBSDInfo)
    }

    init(
        listPIDs: @escaping (UnsafeMutableRawPointer?, Int32) -> Int32,
        readProcess: @escaping (pid_t) -> proc_bsdinfo?
    ) {
        self.listPIDs = listPIDs
        self.readProcess = readProcess
    }

    /// Captures topology with at most three PID-buffer attempts.
    /// - Returns: Unique records with explicit truncation and missing-edge metadata.
    public func capture() -> DarwinProcessListing {
        let initialCount = Int(listPIDs(nil, 0))
        guard initialCount > 0 else {
            return DarwinProcessListing(processes: [], isComplete: false, missingProcessCount: 0)
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
                return resolve(lastPIDs, listingComplete: true)
            }
            capacity = max(capacity * 2, Int(returned) + 32)
        }
        return resolve(lastPIDs, listingComplete: false)
    }

    private func resolve(
        _ pids: [pid_t],
        listingComplete: Bool
    ) -> DarwinProcessListing {
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
        return DarwinProcessListing(
            processes: processes,
            isComplete: listingComplete && missingCount == 0,
            missingProcessCount: missingCount
        )
    }
}
