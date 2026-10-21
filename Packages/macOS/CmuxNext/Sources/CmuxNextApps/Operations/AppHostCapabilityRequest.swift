/// An app operation admitted by its supervisor or native page and routed to its owner.
public nonisolated struct AppHostCapabilityRequest: Sendable {
    /// The calling app (`cmux/coderouter`).
    public var app: String
    /// The full operation name, including its family prefix.
    public var op: String
    /// The operation's original JSON params.
    public var params: AppJSON
    /// `user` inside a gesture, else `script`.
    public var origin: String
    /// The supervisor's app-namespaced mutation key; nil for reads or legacy callers.
    /// Preserve it through owner execution and retries instead of minting another key.
    public var idempotencyKey: String?
    /// The supervisor's actor stamp for audit and attribution, preserved as opaque data.
    /// This metadata does not grant permissions or upgrade the request's origin.
    public var actor: AppJSON?

    /// Creates the value passed to an injected capability owner.
    /// - Parameters:
    ///   - app: The calling app id.
    ///   - op: The full operation name.
    ///   - params: The admitted operation params.
    ///   - origin: The caller's admitted origin; this value does not itself authorize a gesture.
    ///   - idempotencyKey: The supervisor's mutation key, absent for reads and older callers.
    ///   - actor: The supervisor's audit stamp, never an authorization proof.
    public init(app: String, op: String, params: AppJSON, origin: String,
                idempotencyKey: String? = nil, actor: AppJSON? = nil) {
        self.app = app
        self.op = op
        self.params = params
        self.origin = origin
        self.idempotencyKey = idempotencyKey
        self.actor = actor
    }
}
