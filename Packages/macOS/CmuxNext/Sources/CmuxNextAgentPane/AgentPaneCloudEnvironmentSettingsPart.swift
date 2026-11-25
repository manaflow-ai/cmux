public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// Settings > Cloud > Cloud Environments (#47676): `cmux.settings.cloud_environment {method, params}`, one request of the
/// composer's Cloud environment editor (``AgentPaneCloudEnvironmentRequest``: list, get, update, create, derive), run by
/// the composer's own runner, so Settings and the Environment chip edit the same environments, the account's Default
/// among them. A write (`update`, `create`) takes only the person's own click or key in the Settings page, as the
/// composer's does: nothing a script drives the page with saves an environment.
@MainActor
public final class AgentPaneCloudEnvironmentSettingsPart: PageProvider {
    public static let op = "cmux.settings.cloud_environment"
    /// The composer's runner: the reply envelope `{ok, value}` or `{ok: false, error: {code, userMessage}}`.
    public typealias Run = @MainActor (AgentPaneCloudEnvironmentRequest) async -> [String: Any]
    private let run: Run

    public init(run: @escaping Run) { self.run = run }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.op else { throw PageError.unknownOp(op) }
        guard let method = params["method"]?.stringValue,
              let request = AgentPaneCloudEnvironmentRequest(method: method, params: (params["params"] ?? .object([:])).foundationObject as? [String: Any])
        else { throw PageError.invalidParams("method (cloud.environment.list, get, update, create or derive) and params are required") }
        if request.action == "update" || request.action == "create" {
            guard context.page == PageDescriptor.settings.id, context.userGesture else {
                throw PageError(code: "cmux.settings.user_only", message: "only you can change your Cloud environments")
            }
        }
        return try Self.value(await run(request))
    }

    /// The runner's reply as the page's answer: its value, or its failure as a ``PageError`` with the same code.
    nonisolated static func value(_ reply: [String: Any]) throws -> JSONValue {
        if reply["ok"] as? Bool == true { return JSONValue(foundation: reply["value"] ?? NSNull()) ?? .null }
        let error = reply["error"] as? [String: Any]
        throw PageError(code: error?["code"] as? String ?? "cloud_environment.failed",
                        message: error?["userMessage"] as? String ?? "cloud_environment.failed")
    }
}
