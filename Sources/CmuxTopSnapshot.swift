import Foundation
import Darwin
import WebKit
import ObjectiveC.runtime

struct CmuxTopResourceSummary: Sendable {
    var cpuPercent: Double = 0
    var residentBytes: Int64 = 0
    var virtualBytes: Int64 = 0
    var processCount: Int = 0
    var pids: [Int] = []
    var missingPIDs: [Int] = []

    func payload() -> [String: Any] {
        [
            "cpu_percent": cpuPercent,
            "resident_bytes": residentBytes,
            "virtual_bytes": virtualBytes,
            "process_count": processCount,
            "pids": pids,
            "missing_pids": missingPIDs
        ]
    }
}

struct CmuxTopProcessInfo: Sendable {
    let pid: Int
    let parentPID: Int
    let name: String
    let path: String?
    let ttyDevice: Int64?
    let cpuPercent: Double
    let residentBytes: Int64
    let virtualBytes: Int64
    let threadCount: Int
}

final class CmuxTopProcessSnapshot: @unchecked Sendable {
    private static let cpuScale = 2048.0
    private static let pidPathBufferSize = 4096

    let sampledAt: Date
    private let includesProcessDetails: Bool
    private let processesByPID: [Int: CmuxTopProcessInfo]
    private let childrenByParentPID: [Int: [Int]]
    private let pidsByTTYDevice: [Int64: [Int]]

    static func capture(includeProcessDetails: Bool = false) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: allProcesses(includeProcessDetails: includeProcessDetails),
            sampledAt: Date(),
            includesProcessDetails: includeProcessDetails
        )
    }

    private init(
        processes: [CmuxTopProcessInfo],
        sampledAt: Date,
        includesProcessDetails: Bool
    ) {
        self.sampledAt = sampledAt
        self.includesProcessDetails = includesProcessDetails
        self.processesByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })

        var children: [Int: [Int]] = [:]
        var ttyMap: [Int64: [Int]] = [:]
        for process in processes {
            if process.parentPID > 0 {
                children[process.parentPID, default: []].append(process.pid)
            }
            if let ttyDevice = process.ttyDevice {
                ttyMap[ttyDevice, default: []].append(process.pid)
            }
        }
        self.childrenByParentPID = children.mapValues { $0.sorted() }
        self.pidsByTTYDevice = ttyMap.mapValues { $0.sorted() }
    }

    func samplePayload() -> [String: Any] {
        [
            "sampled_at": ISO8601DateFormatter().string(from: sampledAt),
            "source": "sysctl+proc_pidinfo",
            "cpu_source": "kinfo_proc.p_pctcpu",
            "memory_source": "proc_pidinfo.PROC_PIDTASKINFO",
            "process_details": includesProcessDetails
        ]
    }

    func pids(forTTYName ttyName: String) -> Set<Int> {
        guard let device = Self.deviceIdentifier(forTTYName: ttyName) else {
            return []
        }
        return Set(pidsByTTYDevice[device] ?? [])
    }

    func expandedPIDs(rootPIDs: Set<Int>) -> Set<Int> {
        var result: Set<Int> = []
        var stack = Array(rootPIDs.filter { $0 > 0 })

        while let pid = stack.popLast() {
            guard result.insert(pid).inserted else { continue }
            stack.append(contentsOf: childrenByParentPID[pid] ?? [])
        }

        return result
    }

    func summaryPayload(for pids: Set<Int>, rootPIDs: Set<Int> = []) -> [String: Any] {
        summary(for: pids, rootPIDs: rootPIDs).payload()
    }

    func summary(for pids: Set<Int>, rootPIDs: Set<Int> = []) -> CmuxTopResourceSummary {
        let sortedPIDs = pids.filter { $0 > 0 }.sorted()
        var summary = CmuxTopResourceSummary()
        summary.pids = sortedPIDs
        summary.missingPIDs = rootPIDs
            .filter { $0 > 0 && processesByPID[$0] == nil }
            .sorted()

        for pid in sortedPIDs {
            guard let process = processesByPID[pid] else { continue }
            summary.cpuPercent += process.cpuPercent
            summary.residentBytes = Self.clampedAdd(summary.residentBytes, process.residentBytes)
            summary.virtualBytes = Self.clampedAdd(summary.virtualBytes, process.virtualBytes)
            summary.processCount += 1
        }

        return summary
    }

    func processTreePayload(for pids: Set<Int>, rootPIDs explicitRootPIDs: Set<Int> = []) -> [[String: Any]] {
        let allowedPIDs = Set(pids.filter { processesByPID[$0] != nil })
        guard !allowedPIDs.isEmpty else { return [] }

        let roots: [Int]
        if explicitRootPIDs.isEmpty {
            roots = allowedPIDs
                .filter { pid in
                    guard let parent = processesByPID[pid]?.parentPID else { return true }
                    return !allowedPIDs.contains(parent)
                }
                .sorted { processSortKey($0) < processSortKey($1) }
        } else {
            let explicit = explicitRootPIDs.filter { allowedPIDs.contains($0) }
            let orphaned = allowedPIDs.filter { pid in
                explicit.contains(pid) || !allowedPIDs.contains(processesByPID[pid]?.parentPID ?? 0)
            }
            roots = Array(orphaned).sorted { processSortKey($0) < processSortKey($1) }
        }

        var visited: Set<Int> = []
        return roots.compactMap { processTreeNode(pid: $0, allowedPIDs: allowedPIDs, visited: &visited) }
    }

    private func processTreeNode(
        pid: Int,
        allowedPIDs: Set<Int>,
        visited: inout Set<Int>
    ) -> [String: Any]? {
        guard visited.insert(pid).inserted,
              let process = processesByPID[pid] else {
            return nil
        }

        let childNodes = (childrenByParentPID[pid] ?? [])
            .filter { allowedPIDs.contains($0) }
            .sorted { processSortKey($0) < processSortKey($1) }
            .compactMap { processTreeNode(pid: $0, allowedPIDs: allowedPIDs, visited: &visited) }

        var payload: [String: Any] = [
            "kind": "process",
            "pid": process.pid,
            "ppid": process.parentPID,
            "name": process.name,
            "path": process.path ?? NSNull(),
            "thread_count": process.threadCount,
            "resources": summary(for: [pid]).payload(),
            "children": childNodes
        ]
        if let ttyDevice = process.ttyDevice {
            payload["tty_device"] = ttyDevice
        } else {
            payload["tty_device"] = NSNull()
        }
        return payload
    }

    private func processSortKey(_ pid: Int) -> String {
        let process = processesByPID[pid]
        return "\(process?.name ?? ""):\(pid)"
    }

    private static func allProcesses(includeProcessDetails: Bool) -> [CmuxTopProcessInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride

        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
                return []
            }

            var processes = Array(repeating: kinfo_proc(), count: max(1, (length / stride) + 32))
            let result = processes.withUnsafeMutableBufferPointer { buffer in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &length, nil, 0)
            }
            if result == 0 {
                let count = min(processes.count, length / stride)
                return processes.prefix(count).compactMap {
                    processInfo(from: $0, includeProcessDetails: includeProcessDetails)
                }
            }

            guard errno == ENOMEM else {
                return []
            }
        }
        return []
    }

    private static func processInfo(
        from kinfo: kinfo_proc,
        includeProcessDetails: Bool
    ) -> CmuxTopProcessInfo? {
        let pid = Int(kinfo.kp_proc.p_pid)
        guard pid > 0 else { return nil }

        let taskInfo = taskInfo(for: pid)
        let fallbackName = fixedString(kinfo.kp_proc.p_comm)
        let name = includeProcessDetails ? processName(pid: pid, fallback: fallbackName) : fallbackName
        let path = includeProcessDetails ? processPath(pid: pid) : nil
        let rawTTY = Int64(kinfo.kp_eproc.e_tdev)
        let ttyDevice = rawTTY > 0 ? rawTTY : nil

        return CmuxTopProcessInfo(
            pid: pid,
            parentPID: Int(kinfo.kp_eproc.e_ppid),
            name: name.isEmpty ? "pid-\(pid)" : name,
            path: path,
            ttyDevice: ttyDevice,
            cpuPercent: max(0, Double(kinfo.kp_proc.p_pctcpu) / cpuScale * 100.0),
            residentBytes: int64Clamped(taskInfo?.pti_resident_size ?? 0),
            virtualBytes: int64Clamped(taskInfo?.pti_virtual_size ?? 0),
            threadCount: Int(taskInfo?.pti_threadnum ?? 0)
        )
    }

    private static func taskInfo(for pid: Int) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTASKINFO, 0, &info, Int32(expectedSize))
        return size == expectedSize ? info : nil
    }

    private static func processName(pid: Int, fallback: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN + 1))
        let length = proc_name(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return fallback }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }

    private static func processPath(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: pidPathBufferSize)
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func fixedString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { rawBuffer in
            let chars = rawBuffer.bindMemory(to: CChar.self)
            guard let baseAddress = chars.baseAddress else { return "" }
            return String(cString: baseAddress).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func deviceIdentifier(forTTYName ttyName: String) -> Int64? {
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "not a tty" else {
            return nil
        }

        let path: String
        if trimmed.hasPrefix("/dev/") {
            path = trimmed
        } else {
            path = "/dev/\(trimmed)"
        }

        var statInfo = stat()
        guard stat(path, &statInfo) == 0 else {
            return nil
        }
        return Int64(statInfo.st_rdev)
    }

    private static func int64Clamped(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    private static func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        if rhs > 0, lhs > Int64.max - rhs {
            return Int64.max
        }
        return lhs + rhs
    }
}

enum CmuxWebContentProcessIdentifier {
    static func pid(for webView: WKWebView) -> Int? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else {
            return nil
        }

        typealias WebProcessIdentifierFn = @convention(c) (AnyObject, Selector) -> Int32
        let implementation = method_getImplementation(method)
        let pid = unsafeBitCast(implementation, to: WebProcessIdentifierFn.self)(webView, selector)
        return pid > 0 ? Int(pid) : nil
    }
}
