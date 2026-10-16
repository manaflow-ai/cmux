public import Darwin
import Foundation

/// Separates allocated FD-table slots from the live descriptors enumerated by libproc.
public struct DarwinFileDescriptorSnapshot: Sendable {
    /// Allocated FD-table slots, which can remain large after descriptors close.
    public let tableCapacity: Int?
    /// Counts by fixed libproc type label; paths and descriptor numbers are excluded.
    public let typeCounts: [String: Int]
    /// Whether all live descriptors fit in the final read buffer.
    public let isComplete: Bool

    /// Samples allocated table slots and enumerates current descriptors.
    /// - Parameter processID: Process to inspect; defaults to the caller.
    /// Records explicit completeness after at most three reads.
    public init(processID: pid_t = getpid()) {
        var info = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.stride
        let tableCapacity = proc_pidinfo(
            processID, PROC_PIDTBSDINFO, 0, &info, Int32(infoSize)
        ) == infoSize ? Int(info.pbi_nfiles) : nil
        let stride = MemoryLayout<proc_fdinfo>.stride
        let initialBytes = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
        guard tableCapacity != nil, initialBytes > 0 else {
            self.init(tableCapacity: tableCapacity, typeCounts: [:], isComplete: false)
            return
        }
        var capacity = max(32, Int(initialBytes) / stride + 32)
        var typeCounts: [String: Int] = [:]
        for _ in 0..<3 {
            guard capacity <= Int(Int32.max) / stride else { break }
            var records = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let bytes = records.withUnsafeMutableBytes {
                proc_pidinfo(processID, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            guard bytes > 0, Int(bytes) % stride == 0 else { break }
            typeCounts = [:]
            for record in records.prefix(min(capacity, Int(bytes) / stride)) {
                typeCounts[Self.typeName(record.proc_fdtype), default: 0] += 1
            }
            if Int(bytes) < capacity * stride {
                self.init(tableCapacity: tableCapacity, typeCounts: typeCounts, isComplete: true)
                return
            }
            capacity *= 2
        }
        self.init(tableCapacity: tableCapacity, typeCounts: typeCounts, isComplete: false)
    }

    private init(tableCapacity: Int?, typeCounts: [String: Int], isComplete: Bool) {
        self.tableCapacity = tableCapacity
        self.typeCounts = typeCounts
        self.isComplete = isComplete
    }

    /// Returns sanitized counts, keeping capacity distinct from actual open count.
    /// - Returns: JSON-compatible diagnostics; incomplete open counts are `null`.
    public func payload() -> [String: Any] {
        let sampledCount = typeCounts.values.reduce(0, +)
        return [
            "table_capacity": tableCapacity as Any? ?? NSNull(),
            "table_capacity_source": "proc_pidinfo.PROC_PIDTBSDINFO.pbi_nfiles",
            "open_count": isComplete ? sampledCount as Any : NSNull(),
            "sampled_count": sampledCount,
            "type_counts": typeCounts,
            "complete": isComplete,
            "source": "proc_pidinfo.PROC_PIDLISTFDS"
        ]
    }

    private static func typeName(_ type: UInt32) -> String {
        switch type {
        case UInt32(PROX_FDTYPE_VNODE): return "vnode"
        case UInt32(PROX_FDTYPE_SOCKET): return "socket"
        case UInt32(PROX_FDTYPE_PIPE): return "pipe"
        case UInt32(PROX_FDTYPE_KQUEUE): return "kqueue"
        case UInt32(PROX_FDTYPE_PSHM): return "shared_memory"
        case UInt32(PROX_FDTYPE_PSEM): return "semaphore"
        case UInt32(PROX_FDTYPE_FSEVENTS): return "fsevents"
        default: return "other"
        }
    }
}
