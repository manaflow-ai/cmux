internal import CmuxCore

/// Stable publication and baseline state for host-wide fallback port polling.
struct RemotePortPollState {
    private(set) var publishedPorts: [Int] = []
    private(set) var baselinePorts: Set<Int>?
    private let incompleteTTYTransitionRetentionLimit: Int
    private var snapshot = PortScanSnapshotReconciler<RemotePortPollingMode>()
    private var ttyTransitionSnapshot = PortScanSnapshotReconciler<Int>()
    private var incompleteTTYTransitionAttemptCountsByPort: [Int: Int] = [:]

    init(incompleteTTYTransitionRetentionLimit: Int = 2) {
        self.incompleteTTYTransitionRetentionLimit = max(0, incompleteTTYTransitionRetentionLimit)
    }

    /// Applies one scan when its evidence is safe for the selected polling mode.
    @discardableResult
    mutating func apply(
        observedPorts: Set<Int>,
        mode: RemotePortPollingMode,
        completeness: PortScanCompleteness
    ) -> Bool {
        switch mode {
        case .hostWide:
            resetTTYTransitionHistory()
            let stableSnapshot = snapshot.reconcile(
                scannedPorts: [mode: Array(observedPorts)],
                scannedKeys: [mode],
                trackedKeys: [mode],
                completeness: completeness
            )
            publishedPorts = stableSnapshot[mode] ?? []
            if completeness == .complete {
                baselinePorts = nil
            }
            return true

        case .hostWideDelta:
            resetTTYTransitionHistory()
            guard let baselinePorts else {
                guard completeness == .complete else { return false }
                self.baselinePorts = observedPorts
                publishedPorts = []
                snapshot.reset()
                return true
            }
            let stableSnapshot = snapshot.reconcile(
                scannedPorts: [mode: Array(observedPorts.subtracting(baselinePorts))],
                scannedKeys: [mode],
                trackedKeys: [mode],
                completeness: completeness
            )
            publishedPorts = stableSnapshot[mode] ?? []
            return true

        case .ttyScoped:
            return advanceTTYTransition(completeness: completeness)
        }
    }

    /// Starts bounded retention of the currently published fallback ports during TTY handoff.
    mutating func beginTTYTransition() -> Bool {
        if !ttyTransitionSnapshot.snapshot.isEmpty { return true }
        incompleteTTYTransitionAttemptCountsByPort.removeAll()
        guard !publishedPorts.isEmpty else { return false }
        let trackedPorts = Set(publishedPorts)
        ttyTransitionSnapshot.reconcile(
            scannedPorts: Dictionary(uniqueKeysWithValues: trackedPorts.map { ($0, [$0]) }),
            scannedKeys: trackedPorts,
            trackedKeys: trackedPorts,
            completeness: .complete
        )
        return true
    }

    /// Applies host-wide evidence gathered during TTY handoff and returns whether fallback retention finished.
    mutating func advanceTTYTransition(
        observedPorts: Set<Int> = [],
        completeness: PortScanCompleteness
    ) -> Bool {
        guard !publishedPorts.isEmpty else {
            resetTTYTransitionHistory()
            return true
        }
        if ttyTransitionSnapshot.snapshot.isEmpty {
            _ = beginTTYTransition()
        }
        var trackedPorts = Set(publishedPorts)
        let retainedObservations = observedPorts.intersection(trackedPorts)
        if completeness == .incomplete {
            var expiredPorts: Set<Int> = []
            for port in trackedPorts {
                if retainedObservations.contains(port) {
                    incompleteTTYTransitionAttemptCountsByPort.removeValue(forKey: port)
                    continue
                }
                let attemptCount = incompleteTTYTransitionAttemptCountsByPort[port, default: 0] + 1
                if attemptCount > incompleteTTYTransitionRetentionLimit {
                    expiredPorts.insert(port)
                    incompleteTTYTransitionAttemptCountsByPort.removeValue(forKey: port)
                } else {
                    incompleteTTYTransitionAttemptCountsByPort[port] = attemptCount
                }
            }
            trackedPorts.subtract(expiredPorts)
        } else {
            incompleteTTYTransitionAttemptCountsByPort.removeAll()
        }
        let scannedPorts = Dictionary(uniqueKeysWithValues: trackedPorts.map { port in
            (port, retainedObservations.contains(port) ? [port] : [])
        })
        let stableSnapshot = ttyTransitionSnapshot.reconcile(
            scannedPorts: scannedPorts,
            scannedKeys: trackedPorts,
            trackedKeys: trackedPorts,
            completeness: completeness
        )
        publishedPorts = stableSnapshot.values.flatMap { $0 }.sorted()
        if publishedPorts.isEmpty {
            resetTTYTransitionHistory()
        }
        return publishedPorts.isEmpty
    }

    /// Discards mode-specific baseline and reconciliation history while retaining publication.
    mutating func resetScanHistory() {
        baselinePorts = nil
        snapshot.reset()
        resetTTYTransitionHistory()
    }

    /// Clears published ports and all scan history immediately.
    mutating func reset() {
        publishedPorts = []
        resetScanHistory()
    }

    private mutating func resetTTYTransitionHistory() {
        ttyTransitionSnapshot.reset()
        incompleteTTYTransitionAttemptCountsByPort.removeAll()
    }
}
