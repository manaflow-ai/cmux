/// A task op the policy allowed.
public enum MobileTaskOp: Hashable, Sendable {
    case dispatch(MobileTaskDispatch)
    case cancel(task: String)
}
