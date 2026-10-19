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

    /// Creates the value passed to an injected capability owner.
    /// - Parameters:
    ///   - app: The calling app id.
    ///   - op: The full operation name.
    ///   - params: The admitted operation params.
    ///   - origin: The caller's admitted origin; this value does not itself authorize a gesture.
    public init(app: String, op: String, params: AppJSON, origin: String) {
        self.app = app
        self.op = op
        self.params = params
        self.origin = origin
    }
}
