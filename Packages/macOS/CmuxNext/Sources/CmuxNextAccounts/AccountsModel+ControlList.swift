import CmuxNextCodeRouter
public import CmuxNextSettings

// `accounts.list` (`cmux accounts list`): every provider row. No result
// carries an email: accounts are `{account: "acct_…", label: "<redacted
// display>"}`.
extension AccountsModel {
    /// The rows once detection has run. Only Settings > Accounts and a
    /// refresh started detection, so a list read before either reported
    /// every row Checking… forever (a NIGHTLY, 2026-11-21).
    public func controlList(activeTeam: JSONValue, handlesStable: Bool) async -> JSONValue {
        await settle()
        return .object([
            "signed_in": .bool(isSignedInToCmux),
            "active_team": activeTeam,
            "refreshing": .bool(isRefreshing),
            "handles_stable": .bool(handlesStable),
            "providers": .array(rows.map(Self.json)),
        ])
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
