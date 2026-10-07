/// `rb.history` operations.
public enum RbHistoryOp: String, Hashable, Sendable, CaseIterable {
    case back, forward, reload
    case reloadNoCache = "reload_no_cache"
    case stop
}
