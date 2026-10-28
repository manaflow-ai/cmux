/// A complete process census indexed for runaway-session selection.
public struct RunawaySessionCensus: Sendable {
    let processesByPID: [Int: RunawaySessionProcess]
    let pidsByTTYDevice: [Int64: [Int]]
    let pidsByProcessGroupID: [Int: [Int]]

    /// Indexes the processes of one complete census.
    public init(processes: [RunawaySessionProcess]) {
        var processesByPID: [Int: RunawaySessionProcess] = [:]
        var pidsByTTYDevice: [Int64: [Int]] = [:]
        var pidsByProcessGroupID: [Int: [Int]] = [:]
        for process in processes where processesByPID[process.pid] == nil {
            processesByPID[process.pid] = process
            if let ttyDevice = process.ttyDevice {
                pidsByTTYDevice[ttyDevice, default: []].append(process.pid)
            }
            if let processGroupID = process.processGroupID {
                pidsByProcessGroupID[processGroupID, default: []].append(process.pid)
            }
        }
        self.processesByPID = processesByPID
        self.pidsByTTYDevice = pidsByTTYDevice
        self.pidsByProcessGroupID = pidsByProcessGroupID
    }

    func processes(onTTYDevice ttyDevice: Int64) -> [RunawaySessionProcess] {
        (pidsByTTYDevice[ttyDevice] ?? []).compactMap { processesByPID[$0] }
    }

    /// Identifies the app-spawned session root by PID and birth time.
    /// Returns nil when the census cannot establish exactly one root.
    /// - Parameters:
    ///   - ttyDevice: Controlling TTY of the terminal session.
    ///   - appProcessID: Parent app that spawned the session.
    public func sessionIdentifier(ttyDevice: Int64, appProcessID: Int) -> String? {
        let roots = processes(onTTYDevice: ttyDevice).filter { $0.parentPID == appProcessID }
        guard roots.count == 1, let root = roots.first, let started = root.startMicroseconds else { return nil }
        return "\(root.pid):\(started)"
    }

    /// The groups of `processGroupIDs` that are still the same groups they
    /// were in `earlier`: each still holds a process that was its member
    /// there, with the same pid and start time.
    ///
    /// A group ID is free for reuse once its last member exits, so a group
    /// with that ID in this census may be an unrelated job. A process with
    /// an unknown start time proves nothing.
    public func continuingProcessGroupIDs(
        _ processGroupIDs: some Sequence<Int>,
        since earlier: RunawaySessionCensus
    ) -> Set<Int> {
        Set(processGroupIDs.filter { processGroupID in
            (pidsByProcessGroupID[processGroupID] ?? []).contains { pid in
                guard let now = processesByPID[pid],
                      let then = earlier.processesByPID[pid],
                      let started = now.startMicroseconds else { return false }
                return then.processGroupID == processGroupID && then.startMicroseconds == started
            }
        })
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}

extension RunawaySessionCensus {
    /// The usage of the session on `ttyDevice`, or nil when nothing is on it.
    ///
    /// The dominant process is chosen among `candidateGroups` (the groups that
    /// may be signalled) when any hold memory, so the label names the job
    /// rather than the shell.
    public func usage(
        ttyDevice: Int64,
        candidateGroups: Set<Int> = []
    ) -> RunawaySessionUsage? {
        let processes = processes(onTTYDevice: ttyDevice)
        guard !processes.isEmpty else { return nil }
        var memoryBytes: Int64 = 0
        var bytesByGroup: [Int: Int64] = [:]
        for process in processes {
            let bytes = max(0, process.memoryBytes)
            memoryBytes = saturatingAdd(memoryBytes, bytes)
            if let group = process.processGroupID {
                bytesByGroup[group] = saturatingAdd(bytesByGroup[group] ?? 0, bytes)
            }
        }
        let preferred = bytesByGroup.filter { candidateGroups.contains($0.key) && $0.value > 0 }
        let ranked = (preferred.isEmpty ? bytesByGroup : preferred).sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }
        var dominantProcessID: Int?
        if let group = ranked.first?.key {
            if processesByPID[group]?.processGroupID == group,
               processesByPID[group]?.ttyDevice == ttyDevice {
                dominantProcessID = group
            } else {
                dominantProcessID = processes
                    .filter { $0.processGroupID == group }
                    .max { ($0.memoryBytes, -$0.pid) < ($1.memoryBytes, -$1.pid) }?
                    .pid
            }
        }
        return RunawaySessionUsage(
            ttyDevice: ttyDevice,
            memoryBytes: memoryBytes,
            processCount: processes.count,
            dominantProcessID: dominantProcessID,
            memoryIsComplete: processes.allSatisfy(\.memoryIsAvailable)
        )
    }

}
