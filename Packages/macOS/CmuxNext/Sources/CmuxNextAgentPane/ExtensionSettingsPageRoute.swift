public import CmuxNextDaemon
public import CmuxNextPages
public import CmuxNextSettings

/// Settings > Extensions: the settings each installed extension's manifest declares. `list` is the
/// daemon's `apps.settings.list` (every app with settings, its schema and the values it runs with)
/// and `set {app, values}` is `apps.settings.set`, sent as `apps-store` on the app's own connection.
/// The daemon owns the values: it checks a change against the manifest, stores it with the install
/// record and hands it to the running extension at once. `set` runs only on the person's own click
/// or key. Thin: route only.
@MainActor
public final class ExtensionSettingsPageRoute: PageProvider {
    public nonisolated static let prefix = "cmux.settings.extensions."

    private let connection: @MainActor () -> DaemonConnection?

    public init(connection: @escaping @MainActor () -> DaemonConnection?) {
        self.connection = connection
    }

    public func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard context.page == PageDescriptor.settings.id else { throw PageError.unknownOp(op) }
        let request: AppsStoreRequest
        switch op {
        case Self.prefix + "list":
            request = AppsStoreRequest(op: "apps.settings.list")
        case Self.prefix + "set":
            guard context.userGesture else {
                throw PageError(code: "cmux.settings.user_only", message: "only you can change an extension's settings")
            }
            guard let app = params["app"]?.stringValue, let values = params["values"], values.objectValue != nil,
                  let key = params["idempotency_key"]?.stringValue ?? context.opid else {
                throw PageError.invalidParams("app, values and idempotency_key are required")
            }
            let args = try DaemonPageValue.daemonParams([
                "app": .string(app), "values": values, "idempotency_key": .string(key),
            ])
            request = AppsStoreRequest(op: "apps.settings.set", args: .object(args))
        default:
            throw PageError.unknownOp(op)
        }
        guard let connection = connection() else { throw PageError.closed }
        do {
            return try DaemonPageValue.pageValue(try await connection.request(request))
        } catch let error as DaemonError {
            throw DaemonPageValue.pageError(error)
        }
    }
}
