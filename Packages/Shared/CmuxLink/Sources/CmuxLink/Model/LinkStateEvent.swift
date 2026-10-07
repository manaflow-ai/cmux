/// Inputs to `LinkStateMachine`.
public enum LinkStateEvent: Sendable, Hashable {
    case attemptStarted(Int)
    case connected(LinkPath)
    case pathChanged(LinkPath)
    case health(LinkHealth)
    case transportLost(attempt: Int)
    case close(LinkCloseReason)
}
