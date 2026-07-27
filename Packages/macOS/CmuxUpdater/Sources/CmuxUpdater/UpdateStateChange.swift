/// One recorded update-state transition: the ``UpdateStateModel/state`` and
/// ``UpdateStateModel/overrideState`` pair as it was at emission time.
public struct UpdateStateChange {
    /// The state value captured when the transition was emitted.
    public let state: UpdateState
    /// The override state captured when the transition was emitted.
    public let overrideState: UpdateState?
}

extension UpdateStateChange {
    func canCoalesceProgress(with newer: UpdateStateChange) -> Bool {
        guard overrideState == nil, newer.overrideState == nil else { return false }
        switch (state, newer.state) {
        case (.downloading, .downloading),
             (.extracting, .extracting):
            return true
        default:
            return false
        }
    }
}
