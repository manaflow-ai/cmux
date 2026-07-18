import Darwin
import Foundation

private nonisolated let cmuxTopPIDPathBufferSize = 4096

enum CmuxTopTargetedPIDEnumeration: Sendable, Equatable {
    case complete(Set<Int>)
    case incomplete
}

extension CmuxTopProcessSnapshot {
    static func allProcesses(includeProcessDetails: Bool, includeCMUXScope: Bool) -> [CmuxTopProcessInfo] {
        let sampledProcesses = allBSDProcesses()
        guard !sampledProcesses.isEmpty else { return [] }

        var scopeKeyByPID: [Int: CmuxTopProcessScopeCacheKey] = [:]
        scopeKeyByPID.reserveCapacity(sampledProcesses.count)
        for process in sampledProcesses {
            scopeKeyByPID[Int(process.pbi_pid)] = scopeCacheKey(from: process)
        }
        let activeScopeKeys = Set(scopeKeyByPID.values)
        var parentScopeKeys: [CmuxTopProcessScopeCacheKey: CmuxTopProcessScopeCacheKey] = [:]
        parentScopeKeys.reserveCapacity(sampledProcesses.count)
        for process in sampledProcesses {
            let key = scopeCacheKey(from: process)
            let parentPID = Int(process.pbi_ppid)
            guard let parentKey = scopeKeyByPID[parentPID] else { continue }
            parentScopeKeys[key] = parentKey
        }
        let sampledAtNanoseconds = cpuSampleClockNanoseconds()
        var currentCPUSamples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample] = [:]
        var processRecords: [(info: CmuxTopProcessInfo, cpuSampleKey: CmuxTopProcessScopeCacheKey?)] = []
        processRecords.reserveCapacity(sampledProcesses.count)
        for process in sampledProcesses {
            guard let processRecord = processInfo(
                from: process,
                includeProcessDetails: includeProcessDetails,
                includeCMUXScope: includeCMUXScope,
                sampledAtNanoseconds: sampledAtNanoseconds,
                currentCPUSamples: &currentCPUSamples
            ) else {
                continue
            }
            processRecords.append(processRecord)
        }
        let cpuPercentages = cpuPercentages(
            for: currentCPUSamples,
            activeKeys: activeScopeKeys,
            parentKeysByKey: parentScopeKeys,
            sampledAtNanoseconds: sampledAtNanoseconds
        )
        for index in processRecords.indices {
            guard let key = processRecords[index].cpuSampleKey,
                  let cpuPercent = cpuPercentages[key] else { continue }
            processRecords[index].info.cpuPercent = cpuPercent
        }
        if includeCMUXScope {
            pruneCMUXScopeCache(activeKeys: activeScopeKeys)
        }
        return processRecords.map(\.info)
    }

    static func deviceIdentifier(forTTYName ttyName: String) -> Int64? {
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

    /// `proc_listpids(PROC_TTY_ONLY)` scopes completeness to one terminal. A
    /// process elsewhere on the machine that denies `proc_pidinfo` therefore
    /// cannot prevent an otherwise safe pane from hibernating.
    static func processIDs(forTTYDevice ttyDevice: Int64) -> CmuxTopTargetedPIDEnumeration {
        guard ttyDevice > 0, ttyDevice <= Int64(UInt32.max) else { return .incomplete }
        let pidStride = MemoryLayout<pid_t>.stride
        var capacity = 16
        for _ in 0..<4 {
            var pids = Array(repeating: pid_t(), count: capacity)
            let returnedBytes = pids.withUnsafeMutableBufferPointer { buffer in
                proc_listpids(
                    UInt32(PROC_TTY_ONLY),
                    UInt32(ttyDevice),
                    buffer.baseAddress,
                    Int32(buffer.count * pidStride)
                )
            }
            guard returnedBytes >= 0 else { return .incomplete }
            let returnedCount = Int(returnedBytes) / pidStride
            guard returnedCount <= pids.count else { return .incomplete }
            if returnedCount < pids.count {
                return .complete(Set(pids.prefix(returnedCount).map(Int.init).filter { $0 > 0 }))
            }
            capacity *= 2
        }
        return .incomplete
    }

    /// Direct-child enumeration is sufficient for a process-free proof: every
    /// descendant has a direct child on the path from the terminal shell.
    static func childProcessIDs(of pid: Int) -> CmuxTopTargetedPIDEnumeration {
        guard pid > 0, pid <= Int(Int32.max) else { return .incomplete }
        let pidStride = MemoryLayout<pid_t>.stride
        var capacity = 8
        for _ in 0..<4 {
            var pids = Array(repeating: pid_t(), count: capacity)
            let returnedCount = pids.withUnsafeMutableBufferPointer { buffer in
                proc_listchildpids(
                    pid_t(pid),
                    buffer.baseAddress,
                    Int32(buffer.count * pidStride)
                )
            }
            guard returnedCount >= 0, Int(returnedCount) <= pids.count else { return .incomplete }
            if Int(returnedCount) < pids.count {
                return .complete(Set(pids.prefix(Int(returnedCount)).map(Int.init).filter { $0 > 0 }))
            }
            capacity *= 2
        }
        return .incomplete
    }

    private static func processInfo(
        from bsdInfo: proc_bsdinfo,
        includeProcessDetails: Bool,
        includeCMUXScope: Bool,
        sampledAtNanoseconds: UInt64,
        currentCPUSamples: inout [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample]
    ) -> (info: CmuxTopProcessInfo, cpuSampleKey: CmuxTopProcessScopeCacheKey?)? {
        let pid = Int(bsdInfo.pbi_pid)
        guard pid > 0 else { return nil }

        let taskInfo = taskInfo(for: pid)
        let resourceUsage = resourceUsage(for: pid)
        let cacheKey = scopeCacheKey(from: bsdInfo)
        let fallbackName = fixedString(bsdInfo.pbi_comm)
        let name = includeProcessDetails ? processName(pid: pid, fallback: fallbackName) : fallbackName
        let path = includeProcessDetails ? processPath(pid: pid) : nil
        let rawTTY = Int64(bsdInfo.e_tdev)
        let ttyDevice = rawTTY > 0 ? rawTTY : nil
        let cmuxScope = includeCMUXScope
            ? cachedCMUXScope(for: pid, cacheKey: cacheKey, nowNanoseconds: sampledAtNanoseconds)
            : nil
        let rawProcessGroupID = Int(bsdInfo.pbi_pgid)
        let processGroupID = rawProcessGroupID > 0 ? rawProcessGroupID : nil
        let rawTerminalProcessGroupID = Int(bsdInfo.e_tpgid)
        let terminalProcessGroupID = rawTerminalProcessGroupID > 0 ? rawTerminalProcessGroupID : nil
        let memoryBytes: Int64
        let memorySource: CmuxTopProcessMemorySource
        if let resourceUsage {
            memoryBytes = int64Clamped(resourceUsage.ri_phys_footprint)
            memorySource = .physicalFootprint
        } else if let taskInfo {
            memoryBytes = int64Clamped(taskInfo.pti_resident_size)
            memorySource = .residentSize
        } else {
            memoryBytes = 0
            memorySource = .unavailable
        }
        let residentBytes: Int64
        let residentMemorySource: CmuxTopProcessMemorySource
        if let taskInfo {
            residentBytes = int64Clamped(taskInfo.pti_resident_size)
            residentMemorySource = .residentSize
        } else if let resourceUsage {
            residentBytes = int64Clamped(resourceUsage.ri_resident_size)
            residentMemorySource = .rusageResidentSize
        } else {
            residentBytes = 0
            residentMemorySource = .unavailable
        }
        let cpuSampleKey: CmuxTopProcessScopeCacheKey?
        if let taskInfo {
            let currentCPUSample = cpuSample(from: taskInfo, sampledAtNanoseconds: sampledAtNanoseconds)
            currentCPUSamples[cacheKey] = currentCPUSample
            cpuSampleKey = cacheKey
        } else {
            cpuSampleKey = nil
        }

        return (CmuxTopProcessInfo(
            pid: pid,
            parentPID: Int(bsdInfo.pbi_ppid),
            name: name.isEmpty ? "pid-\(pid)" : name,
            path: path,
            ttyDevice: ttyDevice,
            cmuxWorkspaceID: cmuxScope?.workspaceID,
            cmuxSurfaceID: cmuxScope?.surfaceID,
            cmuxAttributionReason: cmuxScope?.attributionReason,
            processGroupID: processGroupID,
            terminalProcessGroupID: terminalProcessGroupID,
            cpuPercent: 0,
            memoryBytes: memoryBytes,
            memorySource: memorySource,
            residentBytes: residentBytes,
            residentMemorySource: residentMemorySource,
            virtualBytes: int64Clamped(taskInfo?.pti_virtual_size ?? 0),
            threadCount: Int(taskInfo?.pti_threadnum ?? 0),
            generationIdentity: AgentPIDProcessIdentity(
                pid: pid_t(pid),
                startSeconds: Int64(bsdInfo.pbi_start_tvsec),
                startMicroseconds: Int64(bsdInfo.pbi_start_tvusec)
            )
        ), cpuSampleKey)
    }

    private static func allBSDProcesses() -> [proc_bsdinfo] {
        let pidStride = MemoryLayout<pid_t>.stride
        func bsdInfos(from pids: [pid_t], count: Int) -> [proc_bsdinfo] {
            pids.prefix(count).compactMap { pid in
                guard pid > 0 else { return nil }
                return bsdInfo(for: Int(pid))
            }
        }

        // proc_listallpids returns a PID count; the buffer size argument is bytes.
        let initialPIDCount = Int(proc_listallpids(nil, 0))
        guard initialPIDCount > 0 else { return [] }
        var capacity = max(1, initialPIDCount + 32)
        var lastPIDs: [pid_t] = []
        var lastCount = 0
        for _ in 0..<3 {
            var pids = Array(repeating: pid_t(), count: capacity)
            let returnedCount = pids.withUnsafeMutableBufferPointer { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count * pidStride))
            }
            guard returnedCount >= 0 else {
                return lastCount > 0 ? bsdInfos(from: lastPIDs, count: lastCount) : []
            }
            let returnedPIDCount = Int(returnedCount)
            let count = min(pids.count, returnedPIDCount)
            if count > 0 {
                lastPIDs = pids
                lastCount = count
            }
            if returnedPIDCount < pids.count {
                return bsdInfos(from: pids, count: count)
            }
            capacity = max(pids.count * 2, returnedPIDCount + 32)
        }
        return lastCount > 0 ? bsdInfos(from: lastPIDs, count: lastCount) : []
    }

    private static func bsdInfo(for pid: Int) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        return size == expectedSize ? info : nil
    }

    private static func taskInfo(for pid: Int) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTASKINFO, 0, &info, Int32(expectedSize))
        return size == expectedSize ? info : nil
    }

    private static func resourceUsage(for pid: Int) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutableBytes(of: &info) { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            // proc_pid_rusage imports as rusage_info_t *; callers pass the concrete
            // rusage struct address cast to that opaque buffer type.
            let buffer = baseAddress.assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(
                pid_t(pid),
                RUSAGE_INFO_V4,
                buffer
            )
        }
        return result == 0 ? info : nil
    }

    private static func processName(pid: Int, fallback: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN + 1))
        let length = proc_name(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return fallback }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }

    private static func processPath(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: cmuxTopPIDPathBufferSize)
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func fixedString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { rawBuffer in
            let endIndex = rawBuffer.firstIndex(of: 0) ?? rawBuffer.endIndex
            return String(decoding: rawBuffer[..<endIndex], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func int64Clamped(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
