enum MainWindowRouteDockState {
    case live(DockSplitStore)
    case frozen(SessionSplitContainerSnapshot)

    func sessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex?
    ) -> SessionSplitContainerSnapshot {
        switch self {
        case .live(let dock):
            dock.sessionSnapshot(
                includeScrollback: includeScrollback,
                restorableAgentIndex: restorableAgentIndex,
                surfaceResumeBindingIndex: surfaceResumeBindingIndex
            )
        case .frozen(let snapshot):
            snapshot
        }
    }
}
