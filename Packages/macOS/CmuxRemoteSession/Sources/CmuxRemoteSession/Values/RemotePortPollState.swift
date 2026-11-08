internal import CmuxCore

/// Stable publication and baseline state for host-wide fallback port polling.
struct RemotePortPollState {
    private(set) var publishedPorts: [Int] = []
    private(set) var baselinePorts: Set<Int>?
    private let incompleteTTYTransitionRetentionLimit: Int
    private var snapshot = PortScanSnapshotReconciler<RemotePortPollingMode>()
    private var ttyTransitionSnapshot = PortScanSnapshotReconciler<RemotePortPollingMode>()
    private var incompleteTTYTransitionAttemptCount = 0

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
        incompleteTTYTransitionAttemptCount = 0
        guard !publishedPorts.isEmpty else { return false }
        ttyTransitionSnapshot.reconcile(
            scannedPorts: [.ttyScoped: publishedPorts],
            scannedKeys: [.ttyScoped],
            trackedKeys: [.ttyScoped],
            completeness: .complete
        )
        return true
    }

    /// Applies TTY scan completeness and returns whether fallback retention finished.
    mutating func advanceTTYTransition(completeness: PortScanCompleteness) -> Bool {
        guard !publishedPorts.isEmpty else {
            resetTTYTransitionHistory()
            return true
        }
        if ttyTransitionSnapshot.snapshot.isEmpty {
            _ = beginTTYTransition()
        }
        if completeness == .incomplete {
            incompleteTTYTransitionAttemptCount += 1
            if incompleteTTYTransitionAttemptCount > incompleteTTYTransitionRetentionLimit {
                publishedPorts = []
                resetTTYTransitionHistory()
                return true
            }
        } else {
            incompleteTTYTransitionAttemptCount = 0
        }
        let stableSnapshot = ttyTransitionSnapshot.reconcile(
            scannedPorts: [:],
            scannedKeys: [.ttyScoped],
            trackedKeys: [.ttyScoped],
            completeness: completeness
        )
        publishedPorts = stableSnapshot[.ttyScoped] ?? []
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
        incompleteTTYTransitionAttemptCount = 0
    }
}
