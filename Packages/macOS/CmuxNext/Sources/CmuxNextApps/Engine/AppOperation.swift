/// Who caused an app's operation (OWNERSHIP-PRINCIPLES "Clients are
/// projections"): `script` by default; `user` for ops an app issues while
/// handling a tap or menu pick in this client, so a focus op from a click
/// may change focus and one from a timer may not.
public nonisolated enum AppOperationOrigin: String, Sendable, Hashable {
    case script
    case user
}

/// One `cmux.<family>.<verb>(params, options)` call from an app, after the
/// host's scope check.
public nonisolated struct AppOperationRequest: Sendable, Hashable {
    /// The app principal (`cmux/github-prs`) and its version.
    public var app: String
    public var appVersion: String
    public var op: String
    public var params: AppJSON
    public var options: AppJSON
    public var origin: AppOperationOrigin
    /// Set for mutations (minted by the host when the app gave none).
    public var idempotencyKey: String?

    public init(app: String, appVersion: String, op: String, params: AppJSON, options: AppJSON = .object([:]),
                origin: AppOperationOrigin = .script, idempotencyKey: String? = nil) {
        self.app = app
        self.appVersion = appVersion
        self.op = op
        self.params = params
        self.options = options
        self.origin = origin
        self.idempotencyKey = idempotencyKey
    }
}

/// Runs app operations for the engine. The App implements it (action.run
/// through the registry, reads from the control snapshot, per-app storage,
/// egress); the module never imports the daemon. Called off the main
/// actor; implementations hop as they need.
public nonisolated protocol AppOperationSink: Sendable {
    func perform(_ request: AppOperationRequest) async -> Result<AppOperationResult, AppOperationError>
}
