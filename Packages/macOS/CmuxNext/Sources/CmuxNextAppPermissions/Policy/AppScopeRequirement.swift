public import CmuxNextApps
public import Foundation

/// What one call needs, from the public scope table and the call's params.
public nonisolated enum AppScopeRequirement: Sendable, Hashable {
    /// The app's own local storage: always allowed while the app runs.
    case own
    /// One scope (`workspace:read`, `net:api.example.com`,
    /// `integration:github:read`, `fs:read`). `root` is the file root id
    /// an `fs.*` op names.
    case scope(String, root: String?)
    /// Listed as never callable by apps.
    case never
    /// Not in the public scope table.
    case unsupported
    /// The params do not name what the scope needs.
    case invalidParams

    /// Op families no app may ever call, whatever the table says (spec
    /// 6.5 "never": grants, installs, policy, accounts, credentials,
    /// approvals, money, destructive).
    public static let neverPrefixes = ["app.install", "app.update", "app.remove", "grant.", "approval.", "policy.",
                                       "account.", "accounts.", "credential.", "billing.", "payment.", "install."]

    /// Resolves `op` with `params` against `table`.
    public static func resolve(op: String, params: AppJSON, table: AppScopeTable) -> AppScopeRequirement {
        if table.never.contains(op) || neverPrefixes.contains(where: { op.hasPrefix($0) }) { return .never }
        guard let entry = table.ops[op] else { return .unsupported }
        switch entry.scope {
        case "storage:local":
            return .own
        case "net:<host>":
            guard let text = params["url"]?.stringValue, text.lowercased().hasPrefix("https://"),
                  let host = URL(string: text)?.host?.lowercased(), !host.isEmpty else { return .invalidParams }
            return .scope("net:\(host)", root: nil)
        case "integration:<provider>":
            guard let provider = params["provider"]?.stringValue, !provider.isEmpty else { return .invalidParams }
            let read = (params["method"]?.stringValue ?? "GET").uppercased() == "GET"
            return .scope("integration:\(provider)\(read ? ":read" : "")", root: nil)
        case let scope where AppScopeKind(scope).isFiles:
            guard let root = params["root"]?.stringValue, !root.isEmpty else { return .invalidParams }
            return .scope(scope, root: root)
        case let scope:
            return .scope(scope, root: nil)
        }
    }
}

public nonisolated extension AppScopeTable {
}
