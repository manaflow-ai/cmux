internal import CmuxCore

/// Stable publication and baseline state for host-wide fallback port polling.
struct RemotePortPollState {
    private(set) var publishedPorts: [Int] = []
    private(set) var baselinePorts: Set<Int>?
    private var snapshot = PortScanSnapshotReconciler<RemotePortPollingMode>()

    /// Applies one scan when its evidence is safe for the selected polling mode.
    @discardableResult
    mutating func apply(
        observedPorts: Set<Int>,
        mode: RemotePortPollingMode,
        completeness: PortScanCompleteness
    ) -> Bool {
        switch mode {
        case .hostWide:
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
            guard completeness == .complete else { return false }
            reset()
            return true
        }
    }

    /// Discards mode-specific baseline and reconciliation history while retaining publication.
    mutating func resetScanHistory() {
        baselinePorts = nil
        snapshot.reset()
    }

    /// Clears published ports and all scan history immediately.
    mutating func reset() {
        publishedPorts = []
        resetScanHistory()
    }
}
