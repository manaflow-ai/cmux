import CmuxNextApps
import CmuxNextCodeRouter
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// The `coderouter.*` ops of the first-party CodeRouter app, mapped onto the
/// existing control methods (`accounts.list`, `coderouter.accounts.list`,
/// `coderouter.machines`). Account rows reach the app only through those
/// socket methods, so the account privacy rule of the socket (opaque `acct_`
/// handles, no email; PR 17063) applies to apps too; `redact` is a second
/// guard that shortens any email-shaped string before it leaves this handler.
/// Ops without a backing method answer `operation.unsupported`, which the app
/// shows as "Not available in this build".
nonisolated struct CodeRouterAppOps: AppHostCapabilityHandler {
    /// Runs one control method in process with the app op's origin.
    let control: @Sendable (_ method: String, _ params: [String: JSONValue]) async throws(AppHostCapabilityError) -> JSONValue

    var families: Set<String> { ["coderouter"] }

    func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        var params: [String: JSONValue] = ["origin": .string(request.origin)]
        if let team = request.params["team"]?.stringValue { params["teamId"] = .string(team) }
        switch request.op {
        case "coderouter.status":
            let accounts = try await control("accounts.list", params)
            let signedIn = accounts["signed_in"]?.boolValue ?? false
            // Signed out is CodeRouter's local mode (the sign-ins on this
            // Mac), not an error; team features ask for a sign-in inline.
            return [
                "signed_in": .bool(signedIn),
                "mode": signedIn ? "account" : "local",
                "refreshing": .bool(accounts["refreshing"]?.boolValue ?? false),
                "scope": signedIn ? "personal" : .null,
                "health": "ok",
            ]
        case "coderouter.detect":
            let accounts = try await control("accounts.list", params)
            return .array((accounts["providers"]?.arrayValue ?? []).map(Self.detected))
        case "coderouter.accounts.list":
            return Self.redact(AppJSON(try await control("coderouter.accounts.list", params)))
        case "coderouter.usage.get":
            return Self.redact(AppJSON(try await control("coderouter.machines", params)))
        default:
            throw .unsupported(request.op)
        }
    }

    /// One `coderouter.detect` row (presence only, never a secret) from a local
    /// accounts row: handle and redacted label, the first source label.
    static func detected(_ row: JSONValue) -> AppJSON {
        let status = row["status"]?.stringValue ?? "missing"
        let text = { (key: String) -> AppJSON in row[key]?.stringValue.map { .string($0.redactingEmails()) } ?? .null }
        return [
            "provider": .string(row["provider"]?.stringValue ?? ""),
            "name": .string(row["name"]?.stringValue ?? ""),
            "status": .string(status),
            "account": text("account"),
            "label": text("label"),
            "plan": text("plan"),
            "linkable": .bool(row["linkable"]?.boolValue ?? false),
            "source": row["sources"]?.arrayValue?.first?.stringValue.map { .string($0.redactingEmails()) } ?? .null,
        ]
    }

    /// Shortens every email-like string, keys included, with the shared
    /// account redactor (any run holding `@`, `＠`, `﹫`, `%40` or `%2540`).
    /// Two keys that shorten to the same text keep the first value instead of
    /// trapping.
    static func redact(_ value: AppJSON) -> AppJSON {
        switch value {
        case .string(let text): .string(text.redactingEmails())
        case .array(let items): .array(items.map(redact))
        case .object(let fields):
            .object(Dictionary(fields.sorted { $0.key < $1.key }.map { ($0.key.redactingEmails(), redact($0.value)) },
                               uniquingKeysWith: { first, _ in first }))
        default: value
        }
    }
}
