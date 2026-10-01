/// What a connected backend can do. A GUI hides what is not supported.
public struct BackendCapabilities: Hashable, Sendable {
    /// Messages can carry files.
    public var attachments: Bool
    /// A message can be sent into a running turn.
    public var steering: Bool
    /// A waiting message can be removed from the queue.
    public var dequeue: Bool
    /// A message that failed for want of files can be retried.
    public var retry: Bool
    /// A conversation can be forked into a new one.
    public var fork: Bool
    /// Older history can be loaded page by page.
    public var backwardPaging: Bool
    /// A resent message never runs twice.
    public var idempotentSend: Bool
    /// Backend-specific feature names beyond these, such as `acpmux.policy`.
    public var extensions: Set<String>
    /// The backend's version string, for diagnostics.
    public var version: String

    /// Creates a capability set.
    /// - Parameters:
    ///   - attachments: Messages can carry files.
    ///   - steering: Messages can steer a running turn.
    ///   - dequeue: Waiting messages can be removed.
    ///   - retry: Failed messages can be retried.
    ///   - fork: Conversations can be forked.
    ///   - backwardPaging: Older history can be paged.
    ///   - idempotentSend: Resends never run twice.
    ///   - extensions: Backend-specific feature names.
    ///   - version: Backend version.
    public init(attachments: Bool = false, steering: Bool = false, dequeue: Bool = false, retry: Bool = false, fork: Bool = false, backwardPaging: Bool = false, idempotentSend: Bool = false, extensions: Set<String> = [], version: String = "") {
        self.attachments = attachments
        self.steering = steering
        self.dequeue = dequeue
        self.retry = retry
        self.fork = fork
        self.backwardPaging = backwardPaging
        self.idempotentSend = idempotentSend
        self.extensions = extensions
        self.version = version
    }
}
