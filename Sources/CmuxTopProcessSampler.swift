import CmuxFoundation
import Darwin
import Foundation

/// Reads one minimal topology census; resources, paths and scope are separate enrichment.
struct CmuxTopProcessSampler: Sendable {
    let reader: any CmuxTopProcessReading
    init(reader: any CmuxTopProcessReading = CmuxTopProcessReader()) { self.reader = reader }

    func capture() throws -> CmuxTopProcessCapture {
        try Task.checkCancellation()
        let startedAt = Date()
        let listing = reader.enumerate()
        let records = processRecords(from: listing.processes, includeResources: false)
        try Task.checkCancellation()
        let missing = listing.missingProcessCount + listing.processes.count - records.count
        let snapshot = CmuxTopProcessSnapshot(
            processes: records, sampledAt: startedAt,
            includesProcessDetails: false, includesCMUXScope: false, includesResources: false,
            enumerationIsComplete: listing.isComplete && missing == 0,
            enumerationMissingProcessCount: missing
        )
        return CmuxTopProcessCapture(listing: listing, snapshot: snapshot, fields: [])
    }

    func processRecords(
        from sampledProcesses: [proc_bsdinfo], includeResources: Bool
    ) -> [CmuxTopProcessInfo] {
        guard !sampledProcesses.isEmpty else { return [] }

        var scopeKeyByPID: [Int: CmuxTopProcessScopeCacheKey] = [:]
        scopeKeyByPID.reserveCapacity(sampledProcesses.count)
        for process in sampledProcesses {
            scopeKeyByPID[Int(process.pbi_pid)] = CmuxTopProcessSnapshot.scopeCacheKey(from: process)
        }
        let activeScopeKeys = Set(scopeKeyByPID.values)
        var parentScopeKeys: [CmuxTopProcessScopeCacheKey: CmuxTopProcessScopeCacheKey] = [:]
        parentScopeKeys.reserveCapacity(sampledProcesses.count)
        for process in sampledProcesses {
            let key = CmuxTopProcessSnapshot.scopeCacheKey(from: process)
            let parentPID = Int(process.pbi_ppid)
            guard let parentKey = scopeKeyByPID[parentPID] else { continue }
            parentScopeKeys[key] = parentKey
        }
        let sampledAtNanoseconds = CmuxTopProcessSnapshot.cpuSampleClockNanoseconds()
        var currentCPUSamples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample] = [:]
        var processRecords: [(info: CmuxTopProcessInfo, cpuSampleKey: CmuxTopProcessScopeCacheKey?)] = []
        processRecords.reserveCapacity(sampledProcesses.count)
        for process in sampledProcesses {
            guard !Task.isCancelled else { break }
            guard let processRecord = processInfo(
                from: process, includeResources: includeResources,
                sampledAtNanoseconds: sampledAtNanoseconds,
                currentCPUSamples: &currentCPUSamples
            ) else {
                continue
            }
            processRecords.append(processRecord)
        }
        guard includeResources else { return processRecords.map(\.info) }
        let cpuPercentages = CmuxTopProcessSnapshot.cpuPercentages(
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
        return processRecords.map(\.info)
    }

    private func processInfo(
        from bsdInfo: proc_bsdinfo, includeResources: Bool,
        sampledAtNanoseconds: UInt64,
        currentCPUSamples: inout [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample]
    ) -> (info: CmuxTopProcessInfo, cpuSampleKey: CmuxTopProcessScopeCacheKey?)? {
        let pid = Int(bsdInfo.pbi_pid)
        guard pid > 0 else { return nil }

        let taskInfo = includeResources ? reader.taskInfo(for: pid) : nil
        let resourceUsage = includeResources ? reader.resourceUsage(for: pid) : nil
        let cacheKey = CmuxTopProcessSnapshot.scopeCacheKey(from: bsdInfo)
        let fallbackName = CmuxTopProcessSnapshot.fixedString(bsdInfo.pbi_comm)
        let rawTTY = Int64(bsdInfo.e_tdev)
        let ttyDevice = rawTTY > 0 ? rawTTY : nil
        let rawProcessGroupID = Int(bsdInfo.pbi_pgid)
        let processGroupID = rawProcessGroupID > 0 ? rawProcessGroupID : nil
        let rawTerminalProcessGroupID = Int(bsdInfo.e_tpgid)
        let terminalProcessGroupID = rawTerminalProcessGroupID > 0 ? rawTerminalProcessGroupID : nil
        let memoryBytes: Int64
        let memorySource: CmuxTopProcessMemorySource
        if let resourceUsage {
            memoryBytes = CmuxTopProcessSnapshot.int64Clamped(resourceUsage.ri_phys_footprint)
            memorySource = .physicalFootprint
        } else if let taskInfo {
            memoryBytes = CmuxTopProcessSnapshot.int64Clamped(taskInfo.pti_resident_size)
            memorySource = .residentSize
        } else {
            memoryBytes = 0
            memorySource = .unavailable
        }
        let residentBytes: Int64
        let residentMemorySource: CmuxTopProcessMemorySource
        if let taskInfo {
            residentBytes = CmuxTopProcessSnapshot.int64Clamped(taskInfo.pti_resident_size)
            residentMemorySource = .residentSize
        } else if let resourceUsage {
            residentBytes = CmuxTopProcessSnapshot.int64Clamped(resourceUsage.ri_resident_size)
            residentMemorySource = .rusageResidentSize
        } else {
            residentBytes = 0
            residentMemorySource = .unavailable
        }
        let cpuSampleKey: CmuxTopProcessScopeCacheKey?
        if let taskInfo {
            let currentCPUSample = CmuxTopProcessSnapshot.cpuSample(from: taskInfo, sampledAtNanoseconds: sampledAtNanoseconds)
            currentCPUSamples[cacheKey] = currentCPUSample
            cpuSampleKey = cacheKey
        } else {
            cpuSampleKey = nil
        }

        guard reader.matches(pid: pid, key: cacheKey) else { return nil }
        return (CmuxTopProcessInfo(
            pid: pid,
            processIdentity: AgentPIDProcessIdentity(
                pid: pid_t(pid), startSeconds: Int64(cacheKey.startSeconds),
                startMicroseconds: Int64(cacheKey.startMicroseconds)
            ),
            parentPID: Int(bsdInfo.pbi_ppid),
            name: fallbackName.isEmpty ? "pid-\(pid)" : fallbackName,
            path: nil,
            ttyDevice: ttyDevice,
            cmuxWorkspaceID: nil,
            cmuxSurfaceID: nil,
            cmuxAttributionReason: nil,
            processGroupID: processGroupID,
            terminalProcessGroupID: terminalProcessGroupID,
            cpuPercent: 0,
            memoryBytes: memoryBytes,
            memorySource: memorySource,
            residentBytes: residentBytes,
            residentMemorySource: residentMemorySource,
            virtualBytes: CmuxTopProcessSnapshot.int64Clamped(taskInfo?.pti_virtual_size ?? 0),
            threadCount: Int(taskInfo?.pti_threadnum ?? 0)
        ), cpuSampleKey)
    }

}
