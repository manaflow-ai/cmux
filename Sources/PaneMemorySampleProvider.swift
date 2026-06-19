import CmuxPanes
import Foundation

/// App-side conformer for the panes package's `PaneMemorySampleProviding` seam.
///
/// Attributes each pane's process-tree memory by controlling tty against the
/// live `top`-style process snapshot. The snapshot subsystem
/// (`CmuxTopProcessSnapshot`) is app-target and shared with other consumers, so
/// it stays here and the panes package reaches it only through this seam. The
/// summation/process-group selection logic is byte-identical to the former
/// `PaneMemoryGuardrail.compute*` statics; it is exercised by
/// `PaneMemoryGuardrailTests` against fixture snapshots.
struct PaneMemorySampleProvider: PaneMemorySampleProviding {
    func cachedSamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64
    ) -> [PaneMemorySample] {
        Self.computeSamples(
            descriptors: descriptors,
            thresholdBytes: thresholdBytes,
            snapshot: CmuxTopProcessSnapshot.captureCached(maximumAge: 2)
        )
    }

    func freshSamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64
    ) -> [PaneMemorySample] {
        Self.computeSamples(
            descriptors: descriptors,
            thresholdBytes: thresholdBytes,
            snapshot: CmuxTopProcessSnapshot.capture()
        )
    }

    static func computeSamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64,
        snapshot: CmuxTopProcessSnapshot
    ) -> [PaneMemorySample] {
        let clearBytes = Int64(Double(thresholdBytes) * PaneMemoryGuardrailEngine.clearFraction)
        return descriptors.map { descriptor in
            var rootPIDs = snapshot.pids(forCMUXSurfaceID: descriptor.panelId)
            if let ttyName = descriptor.ttyName {
                rootPIDs.formUnion(snapshot.pids(forTTYName: ttyName))
            }
            let pids = snapshot.expandedPIDs(rootPIDs: rootPIDs)
            let summary = snapshot.summary(for: pids)
            let pgids = memoryPressureProcessGroupIDs(
                in: snapshot,
                pids: pids,
                clearBytes: clearBytes
            )
            let foregroundCommand = descriptor.foregroundPID
                .flatMap { snapshot.process(pid: $0)?.name }
            return PaneMemorySample(
                descriptor: descriptor,
                memoryBytes: summary.memoryBytes,
                residentBytes: summary.residentBytes,
                memoryPressureProcessGroupIDs: pgids,
                foregroundCommand: foregroundCommand
            )
        }
    }

    static func memoryPressureProcessGroupIDs(
        in snapshot: CmuxTopProcessSnapshot,
        pids: Set<Int>,
        clearBytes: Int64
    ) -> [Int] {
        var totalBytes: Int64 = 0
        var bytesByProcessGroup: [Int: Int64] = [:]
        for pid in pids {
            guard let process = snapshot.process(pid: pid) else { continue }
            let memoryBytes = max(0, process.memoryBytes)
            totalBytes = totalBytes.addingReportingOverflow(memoryBytes).overflow
                ? Int64.max
                : totalBytes + memoryBytes
            guard let processGroupID = process.processGroupID, processGroupID > 1 else { continue }
            let current = bytesByProcessGroup[processGroupID] ?? 0
            bytesByProcessGroup[processGroupID] = current.addingReportingOverflow(memoryBytes).overflow
                ? Int64.max
                : current + memoryBytes
        }

        guard totalBytes > clearBytes else { return [] }
        var selectedBytes: Int64 = 0
        var selectedProcessGroups: [Int] = []
        for (processGroupID, memoryBytes) in bytesByProcessGroup.sorted(by: {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }) where memoryBytes > 0 {
            selectedProcessGroups.append(processGroupID)
            selectedBytes = selectedBytes.addingReportingOverflow(memoryBytes).overflow
                ? Int64.max
                : selectedBytes + memoryBytes
            if totalBytes - selectedBytes < clearBytes { break }
        }
        return selectedProcessGroups.sorted()
    }
}
