import Foundation

extension CmuxTopProcessSampler {
    /// Adds missing fields to the same census without repeating its resource reads.
    func enrich(_ capture: CmuxTopProcessCapture, fields: CmuxTopProcessFields) throws -> CmuxTopProcessCapture {
        try enrich(capture, fields: fields, memo: nil).capture
    }

    /// Adds missing fields, reusing `memo`'s name, path and scope reads for
    /// each process image it already read (same PID and exec identity).
    /// - Returns: The enriched census and the memo of this census's images.
    func enrich(
        _ capture: CmuxTopProcessCapture, fields: CmuxTopProcessFields, memo: CmuxTopProcessEnrichmentMemo?
    ) throws -> (capture: CmuxTopProcessCapture, memo: CmuxTopProcessEnrichmentMemo) {
        let missing = fields.subtracting(capture.fields)
        var nextMemo = CmuxTopProcessEnrichmentMemo()
        guard !missing.isEmpty else { return (capture, memo ?? nextMemo) }
        let census = capture.snapshot.sampledAt
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
            // A process that exited after the listing is absent, not unreadable:
            // only a live process we failed to read leaves the census incomplete.
            // A reused PID is still live and still counts as missing.
            guard let resources else {
                if !reader.processHasExited(pid: pid) { missingCount += 1 }
                continue
            }
            let key = CmuxTopProcessSnapshot.scopeCacheKey(from: bsd)
            // One cheap read names the process image; an exec or a reused PID
            // misses the memo, so its argv/environment are read again.
            let memoKey = memo != nil && readsIdentitySensitiveData
                ? reader.execIdentity(pid: pid).map { CmuxTopProcessEnrichmentMemo.Key(pid: pid, identity: $0) }
                : nil
            let known = memoKey.flatMap { memo?.entry(for: $0, at: census) }
            let knownDetails = missing.contains(.details) ? known?.details : nil
            let knownScope = missing.contains(.scope) ? known?.scope : nil
            let needsDetails = missing.contains(.details) && knownDetails == nil
            let needsScope = missing.contains(.scope) && knownScope == nil
            let reads = needsDetails || needsScope
            guard !reads || reader.matches(pid: pid, key: key) else {
                if !reader.processHasExited(pid: pid) { missingCount += 1 }
                continue
            }
            let name = knownDetails?.name
                ?? (needsDetails ? reader.processName(pid: pid, fallback: process.name) : process.name)
            let path = knownDetails.map(\.path)
                ?? (needsDetails ? reader.processPath(pid: pid) : process.path)
            let scope: CmuxTopProcessScope? = knownScope
                ?? (needsScope ? reader.scope(for: pid, key: key) : nil)
            guard !reads || reader.matches(pid: pid, key: key) else {
                if !reader.processHasExited(pid: pid) { missingCount += 1 }
                continue
            }
            if let memoKey {
                // Only reads whose identity check passed after them are kept.
                var entry = known ?? CmuxTopProcessEnrichmentMemo.Entry(readAt: census)
                if missing.contains(.details) { entry.details = .init(name: name, path: path) }
                if missing.contains(.scope) { entry.scope = .some(scope) }
                nextMemo.set(entry, for: memoKey)
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
        // A resources-only enrichment read no images: the memo stays as it was.
        let keptMemo = readsIdentitySensitiveData ? nextMemo : (memo ?? nextMemo)
        return (CmuxTopProcessCapture(listing: capture.listing, snapshot: snapshot, fields: combined), keptMemo)
    }
}
