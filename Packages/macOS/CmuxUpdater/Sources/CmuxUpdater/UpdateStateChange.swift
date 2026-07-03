/// One recorded update-state transition: the ``UpdateStateModel/state`` and
/// ``UpdateStateModel/overrideState`` pair as it was at emission time.
public struct UpdateStateChange {
    /// The state value captured when the transition was emitted.
    public let state: UpdateState
    /// The override state captured when the transition was emitted.
    public let overrideState: UpdateState?
}
