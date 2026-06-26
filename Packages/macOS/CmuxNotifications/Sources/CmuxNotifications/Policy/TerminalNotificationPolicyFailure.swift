/// A failure raised while evaluating a notification-policy hook: which hook
/// failed, the config source it came from, and a human-readable message.
public struct TerminalNotificationPolicyFailure: Error, Sendable, Hashable {
    /// The id of the hook that failed.
    public let hookId: String
    /// The config source path the hook was resolved from, if any.
    public let sourcePath: String?
    /// A human-readable description of the failure.
    public let message: String

    /// Creates a notification-policy failure.
    public init(hookId: String, sourcePath: String?, message: String) {
        self.hookId = hookId
        self.sourcePath = sourcePath
        self.message = message
    }
}
