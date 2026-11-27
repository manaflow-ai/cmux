import CmuxNextAccounts
import CmuxNextCodeRouter
import CmuxNextControl
import Foundation

// `accounts.list`: every provider row (status, account label, sources).
// No result carries an email: accounts are `{account: "acct_…", label:
// "<redacted display>"}`.
extension AppControl {
    func registerAccountsMethods(_ services: AppServices) {
        service?.router.register([
            .mainActor("accounts.list") { _ in
                let model = services.accounts.model
                return .value(.object([
                    "signed_in": .bool(model.isSignedInToCmux),
                    "active_team": services.cloud.auth.activeTeam.team.map { .object(["id": .string($0.id), "name": .string($0.displayName)]) } ?? .null,
                    "refreshing": .bool(model.isRefreshing),
                    "handles_stable": .bool(services.accounts.handlesStable),
                    "providers": .array(model.rows.map(Self.json)),
                ]))
            },
        ])
    }

    static func json(_ row: AccountRowState) -> JSONValue {
        let phase: String = switch row.phase {
        case .idle: "idle"
        case .detecting: "detecting"
        case .reauthenticating: "reauthenticating"
        }
        let outcome: JSONValue = switch row.outcome {
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
        ])
    }
}
