/// A Cloud move or bring-back failure, with the action its retry can safely take.
public nonisolated struct CloudMoveFailure: Error {
    /// The failure as the toast and CLI show it.
    public let message: String
    /// What Retry does; none when retrying cannot help.
    public var retry: CloudMoveRetries.Retry?

    /// Creates a failure without changing the chat or its retry policy.
    public init(message: String, retry: CloudMoveRetries.Retry? = nil) {
        self.message = message
        self.retry = retry
    }
}
