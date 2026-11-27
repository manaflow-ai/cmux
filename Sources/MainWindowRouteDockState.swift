@MainActor
enum MainWindowRouteDockState {
    case live(DockSplitStore)
    /// Full-fidelity value retained after the live Dock owner is torn down.
    case frozen(SessionSplitContainerSnapshot)

    func sessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex?,
        downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable: Bool = false
    ) -> SessionSplitContainerSnapshot {
        switch self {
        case .live(let dock):
            return dock.sessionSnapshot(
                includeScrollback: includeScrollback,
                restorableAgentIndex: restorableAgentIndex,
                surfaceResumeBindingIndex: surfaceResumeBindingIndex,
                downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable:
                    downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable
            )
        case .frozen(var snapshot):
            guard !includeScrollback else { return snapshot }
            for index in snapshot.panels.indices {
                snapshot.panels[index].terminal?.scrollback = nil
            }
            return snapshot
        }
    }
}
