import CmuxNextApps
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
            return [
                "signed_in": .bool(signedIn),
                "refreshing": .bool(accounts["refreshing"]?.boolValue ?? false),
                "scope": signedIn ? "personal" : .null,
                "health": signedIn ? "ok" : "signed_out",
            ]
        case "coderouter.accounts.list":
            return Self.redact(AppJSON(try await control("coderouter.accounts.list", params)))
        case "coderouter.usage.get":
            return Self.redact(AppJSON(try await control("coderouter.machines", params)))
        default:
            throw .unsupported(request.op)
        }
    }

    /// Shortens every email-shaped string (`someone@example.com` -> `s…@e…`), keys included.
    static func redact(_ value: AppJSON) -> AppJSON {
        switch value {
        case .string(let text): .string(redactEmails(text))
        case .array(let items): .array(items.map(redact))
        case .object(let fields): .object(Dictionary(uniqueKeysWithValues: fields.map { (redactEmails($0.key), redact($0.value)) }))
        default: value
        }
    }

    static func redactEmails(_ text: String) -> String {
        guard text.contains("@") else { return text }
        return text.replacing(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/) { match in
            let parts = match.output.split(separator: "@", maxSplits: 1)
            let local = parts.first?.first.map(String.init) ?? ""
            let domain = parts.count > 1 ? parts[1].first.map(String.init) ?? "" : ""
            return "\(local)…@\(domain)…"
        }
    }
}
