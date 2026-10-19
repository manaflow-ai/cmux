import CmuxFoundation

/// App adapter that projects only records from one captured descendant topology.
typealias MemoryResourceDiagnostics = ProcessMemoryDiagnostics

extension ProcessMemoryDiagnostics {
    init(snapshot: CmuxTopProcessSnapshot, appPID: Int) {
        let pids = snapshot.expandedPIDs(rootPIDs: [appPID]).subtracting([appPID])
        self.init(
            descendants: pids.lazy.compactMap { pid in
                guard let process = snapshot.process(pid: pid) else { return nil }
                return ProcessMemorySample(
                    name: process.name,
                    residentBytes: process.residentMemorySource == .unavailable ? nil : process.residentBytes,
                    physicalFootprintBytes: process.memorySource == .physicalFootprint ? process.memoryBytes : nil,
                    workspaceID: process.cmuxWorkspaceID
                )
            },
            enumerationComplete: snapshot.enumerationIsComplete && snapshot.process(pid: appPID) != nil,
            enumerationMissingCount: snapshot.enumerationMissingProcessCount
        )
    }
}
