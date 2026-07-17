/// A Git diff lookup that distinguishes absence from command failures.
public enum GitDiffQueryResult<Value: Sendable>: Sendable {
    /// The requested value was read successfully.
    case success(Value)
    /// The requested repository or file does not exist.
    case notFound
    /// Git could not be launched or exited unsuccessfully.
    case failed
    /// Git exceeded the configured subprocess deadline.
    case timedOut
}
