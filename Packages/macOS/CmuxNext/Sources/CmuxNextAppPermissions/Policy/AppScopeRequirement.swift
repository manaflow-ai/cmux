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
    /// The bundled table plus the operations section 3.3 proposes (file
    /// roots, usage, CodeRouter, history, documents). Demos and tests use
    /// it until the catalog generator emits these entries; an owner still
    /// answers `operation.unsupported` until it implements the op.
    func addingProposedOperations() -> AppScopeTable {
        var entries = ops.mapValues { ($0.scope, $0.opClass) }
        for (op, scope, opClass) in Self.proposedOperations where entries[op] == nil {
            entries[op] = (scope, opClass)
        }
        return Self.permissionsTable(apiVersion: apiVersion, ops: entries, never: never) ?? self
    }

    /// A table from `(scope, class)` pairs. `Entry` has no public
    /// initializer, so the table round-trips through its JSON form.
    static func permissionsTable(apiVersion: String = "1.0.0", ops: [String: (scope: String, opClass: String)],
                                 never: Set<String>) -> AppScopeTable? {
        let document: AppJSON = .object([
            "apiVersion": .string(apiVersion),
            "ops": .object(ops.mapValues { .object(["scope": .string($0.scope), "class": .string($0.opClass)]) }),
            "never": .array(never.sorted().map(AppJSON.string)),
        ])
        return try? AppScopeTable(data: Data(document.jsonText.utf8))
    }

    /// `(op, scope, class)` for the proposed operations.
    static let proposedOperations: [(String, String, String)] = [
        ("fs.search", "fs:read", "read"), ("fs.read", "fs:read", "read"), ("fs.write", "fs:write", "mutation"),
        ("usage.list", "usage:read", "read"), ("usage.refresh", "usage:read", "mutation"),
        ("coderouter.status", "coderouter:read", "read"), ("coderouter.accounts.list", "coderouter:read", "read"),
        ("coderouter.usage.get", "coderouter:read", "read"), ("coderouter.route.test", "coderouter:write", "mutation"),
        ("coderouter.accounts.share", "coderouter:write", "mutation"),
        ("coderouter.keys.list", "coderouter:keys", "read"), ("coderouter.keys.create", "coderouter:keys", "mutation"),
        ("coderouter.keys.revoke", "coderouter:keys", "mutation"),
        ("browser.history.search", "history:read", "read"), ("terminal.search", "terminal:read", "read"),
        ("app.documents.list", "storage:local", "read"), ("app.documents.get", "storage:local", "read"),
        ("app.documents.put", "storage:local", "mutation"), ("app.documents.delete", "storage:local", "mutation"),
        ("clipboard.write", "clipboard:write", "mutation"),
    ]
}
