import Foundation

extension CmuxTopProcessSampler {
    /// Adds missing fields to the same census without repeating its resource reads.
    func enrich(_ capture: CmuxTopProcessCapture, fields: CmuxTopProcessFields) throws -> CmuxTopProcessCapture {
        let missing = fields.subtracting(capture.fields)
        guard !missing.isEmpty else { return capture }
        let resourcesByPID: [Int: CmuxTopProcessInfo]
        if missing.contains(.resources) {
            resourcesByPID = Dictionary(uniqueKeysWithValues: processRecords(
                from: capture.listing.processes, includeResources: true
            ).map { ($0.pid, $0) })
        } else { resourcesByPID = [:] }
        var records: [CmuxTopProcessInfo] = []
        records.reserveCapacity(capture.snapshot.processesByPID.count)
        var missingCount = capture.snapshot.enumerationMissingProcessCount
        let readsIdentitySensitiveData = missing.contains(.details) || missing.contains(.scope)
        for bsd in capture.listing.processes {
            try Task.checkCancellation()
            let pid = Int(bsd.pbi_pid)
            guard let process = capture.snapshot.process(pid: pid) else { continue }
            let resources = missing.contains(.resources) ? resourcesByPID[pid] : process
            guard let resources else { missingCount += 1; continue }
            let key = CmuxTopProcessSnapshot.scopeCacheKey(from: bsd)
            guard !readsIdentitySensitiveData || reader.matches(pid: pid, key: key) else {
                missingCount += 1
                continue
            }
            let name = missing.contains(.details)
                ? reader.processName(pid: pid, fallback: process.name) : process.name
            let path = missing.contains(.details) ? reader.processPath(pid: pid) : process.path
            let scope = missing.contains(.scope) ? reader.scope(for: pid, key: key) : nil
            guard !readsIdentitySensitiveData || reader.matches(pid: pid, key: key) else {
                missingCount += 1
                continue
            }
            records.append(CmuxTopProcessInfo(
                pid: pid, processIdentity: process.processIdentity,
                parentPID: process.parentPID, name: name, path: path,
                ttyDevice: process.ttyDevice,
                cmuxWorkspaceID: missing.contains(.scope) ? scope?.workspaceID : process.cmuxWorkspaceID,
                cmuxSurfaceID: missing.contains(.scope) ? scope?.surfaceID : process.cmuxSurfaceID,
                cmuxAttributionReason: missing.contains(.scope) ? scope?.attributionReason : process.cmuxAttributionReason,
                processGroupID: process.processGroupID, terminalProcessGroupID: process.terminalProcessGroupID,
                cpuPercent: resources.cpuPercent, memoryBytes: resources.memoryBytes, memorySource: resources.memorySource,
                residentBytes: resources.residentBytes, residentMemorySource: resources.residentMemorySource,
                virtualBytes: resources.virtualBytes, threadCount: resources.threadCount
            ))
        }
        let combined = capture.fields.union(missing)
        let snapshot = CmuxTopProcessSnapshot(
            processes: records, sampledAt: capture.snapshot.sampledAt,
            includesProcessDetails: combined.contains(.details), includesCMUXScope: combined.contains(.scope),
            includesResources: combined.contains(.resources),
            enumerationIsComplete: capture.snapshot.enumerationIsComplete && missingCount == 0,
            enumerationMissingProcessCount: missingCount
        )
        return CmuxTopProcessCapture(listing: capture.listing, snapshot: snapshot, fields: combined)
    }
}
