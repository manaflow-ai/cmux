import CmuxNextAccounts
import CmuxNextCodeRouter
import CmuxNextControl
import CmuxNextSettings
import Foundation

// `accounts.list`: every provider row (status, account label, sources,
// CodeRouter links). `coderouter.*`: the methods the shipped `cmux
// coderouter status|machines|claude …` CLI sends (CLI/CMUXCLI+Coderouter.swift),
// passed through to the CodeRouter control plane as the signed-in user. A
// credential the CLI sends travels CLI -> local socket -> this handler ->
// cmux backend and is never logged or stored (plans/cmux-next/coderouter.md).
// No result carries an email: accounts are `{account: "acct_…", label:
// "<redacted display>"}` (CodeRouterClient.request redacts the replies).
extension AppControl {
    func registerAccountsMethods(_ services: AppServices) {
        let network: ControlMethod.Deadline = .fixed(.seconds(20))
        service?.router.register([
            .mainActor("accounts.list") { _ in
                let model = services.accounts.model
                return .value(.object([
                    "signed_in": .bool(model.isSignedInToCmux),
                    "refreshing": .bool(model.isRefreshing),
                    "handles_stable": .bool(services.accounts.handlesStable),
                    "providers": .array(model.rows.map(Self.json)),
                ]))
            },
            Self.passthrough("coderouter.claude_upstream.get", services) { client, team, _ in
                try await client.request("GET", "/api/coderouter/claude-upstream", team: team)
            }.withDeadline(network),
            Self.passthrough("coderouter.claude_upstream.add", services) { client, team, params in
                try await client.request("POST", "/api/coderouter/claude-upstream", body: try Self.claudeBody(params), team: team)
            }.withDeadline(network),
            Self.passthrough("coderouter.claude_upstream.set", services) { client, team, params in
                try await client.request("POST", "/api/coderouter/claude-upstream", body: try Self.claudeBody(params), team: team)
            }.withDeadline(network),
            Self.passthrough("coderouter.claude_upstream.update", services) { client, team, params in
                var body: [String: any Sendable] = [:]
                if let label = params["label"]?.stringValue { body["label"] = label }
                if let state = params["state"]?.stringValue {
                    guard state == "active" || state == "disabled" else { throw ControlError.invalidParams("`state` must be active or disabled.") }
                    body["state"] = state
                }
                guard !body.isEmpty else { throw ControlError.invalidParams("coderouter.claude_upstream.update needs `label` or `state`.") }
                return try await client.request("PATCH", "/api/coderouter/claude-upstream/" + (try Self.accountID(params)), body: body, team: team)
            }.withDeadline(network),
            Self.passthrough("coderouter.claude_upstream.remove", services) { client, team, params in
                try await Self.idempotentDelete(client, "/api/coderouter/claude-upstream/" + (try Self.accountID(params)), team: team)
            }.withDeadline(network),
            Self.passthrough("coderouter.claude_upstream.clear", services) { client, team, _ in
                try await Self.idempotentDelete(client, "/api/coderouter/claude-upstream", team: team)
            }.withDeadline(network),
            Self.passthrough("coderouter.machines", services) { client, team, _ in
                try await client.request("GET", "/api/coderouter/vm-usage/team", team: team)
            }.withDeadline(network),
            Self.passthrough("coderouter.accounts.list", services) { client, team, _ in
                try await client.request("GET", "/api/coderouter/accounts", team: team)
            }.withDeadline(network),
        ])
    }

    /// A main-actor method that captures the client, then calls CodeRouter
    /// off the main actor and returns the server's JSON object.
    private static func passthrough(_ name: String, _ services: AppServices,
                                    _ call: @escaping @Sendable (CodeRouterClient, String?, [String: JSONValue]) async throws -> Data)
        -> ControlMethod {
        .mainActor(name) { request in
            if let refusal = Self.policyRefusal(name, disabled: services.registry.disabledFeatures) { throw refusal }
            guard let client = services.accounts.client else { throw ControlError(code: "unavailable", message: "Cloud is not available in this build") }
            let params = request.params
            let team = (params["teamId"] ?? params["team_id"])?.stringValue
            return .followUp {
                do {
                    let data = try await call(client, team, params)
                    return data.isEmpty ? .object([:]) : try JSONValue.parse(data)
                } catch let error as CodeRouterError {
                    throw ControlError(code: Self.code(error), message: error.description)
                }
            }
        }
    }

    nonisolated private static func code(_ error: CodeRouterError) -> String {
        switch error {
        case .notSignedIn: "not_signed_in"
        case .timedOut: "timeout"
        case .http(let status, let code, _): code ?? "http_\(status)"
        case .transport: "unavailable"
        case .decoding: "bad_response"
        }
    }

    /// DELETE where a 404 means "already gone": `{removed: false, count: 0}`.
    nonisolated private static func idempotentDelete(_ client: CodeRouterClient, _ path: String, team: String?) async throws -> Data {
        do {
            return try await client.request("DELETE", path, team: team)
        } catch CodeRouterError.http(status: 404, _, _) {
            return Data(#"{"removed":false,"count":0}"#.utf8)
        }
    }

    nonisolated private static func accountID(_ params: [String: JSONValue]) throws -> String {
        guard let id = params["accountId"]?.stringValue, !id.isEmpty else { throw ControlError.invalidParams("`accountId` is required.") }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed), encoded != ".", encoded != ".." else {
            throw ControlError.invalidParams("invalid `accountId`")
        }
        return encoded
    }

    /// Only the fields `POST /api/coderouter/claude-upstream` accepts; the
    /// server validates their shapes. New accounts stay private.
    nonisolated private static func claudeBody(_ params: [String: JSONValue]) throws -> [String: any Sendable] {
        guard let kind = params["kind"]?.stringValue, ["anthropic_oauth", "anthropic_api_key", "bedrock"].contains(kind) else {
            throw ControlError.invalidParams("`kind` must be anthropic_oauth, anthropic_api_key or bedrock.")
        }
        var body: [String: any Sendable] = ["kind": kind, "visibility": "private"]
        for key in ["label", "token", "apiKey", "region", "accessKeyId", "secretAccessKey", "sessionToken"] {
            if let value = params[key]?.stringValue { body[key] = value }
        }
        if let models = params["modelIds"]?.objectValue {
            body["modelIds"] = models.compactMapValues(\.stringValue)
        }
        return body
    }

    static func json(_ row: AccountRowState) -> JSONValue {
        let phase: String = switch row.phase {
        case .idle: "idle"
        case .detecting: "detecting"
        case .reauthenticating: "reauthenticating"
        case .connecting: "connecting"
        case .removing: "removing"
        }
        let outcome: JSONValue = switch row.outcome {
        case .connected: "connected"
        case .removed: "removed"
        case .failed(let message): .object(["failed": .string(message)])
        case nil: .null
        }
        return .object([
            "provider": .string(row.provider.rawValue),
            "name": .string(row.provider.displayName),
            "status": row.status.map { .string($0.rawValue) } ?? .null,
            "account": row.detection?.account.map { .string($0.handle) } ?? .null,
            "label": row.detection?.account.map { .string($0.display) } ?? .null,
            "detail": row.detection?.detail.map(JSONValue.string) ?? .null,
            "plan": row.detection?.plan.map(JSONValue.string) ?? .null,
            "sources": .array((row.detection?.sources ?? []).map { .string($0.label) }),
            "phase": .string(phase),
            "outcome": outcome,
            "can_connect": .bool(row.canConnect),
            "linkable": .bool(row.isLinkable),
            "linked": .array(row.linked.map { account in
                .object(["id": .string(account.id), "account": .string(account.account.handle), "label": .string(account.label),
                         "state": .string(account.state),
                         "family": .string(account.family.rawValue), "visibility": account.visibility.map(JSONValue.string) ?? .null])
            }),
        ])
    }
}
