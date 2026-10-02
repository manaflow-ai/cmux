public import Foundation

/// `scopes.json` (generated from the operation catalog): the scope each op
/// needs and the ops apps may never call. The host checks every call
/// against the app's granted scopes before anything runs (spec 6.5); the
/// VM is untrusted, so the runtime's own `ops` filter is only a courtesy.
public nonisolated struct AppScopeTable: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        /// `workspace:read`, `net:<host>`, `integration:<provider>`, `storage:local`.
        public var scope: String
        /// `read`, `mutation`, or `runtime` (host-provided ops).
        public var opClass: String
    }

    public var apiVersion: String
    public var ops: [String: Entry]
    public var never: Set<String>

    public init(apiVersion: String = "1.0.0", ops: [String: Entry] = [:], never: Set<String> = []) {
        self.apiVersion = apiVersion
        self.ops = ops
        self.never = never
    }

    public init(data: Data) throws {
        let json = try AppJSON.parse(data)
        apiVersion = json["apiVersion"]?.stringValue ?? "1.0.0"
        ops = (json["ops"]?.objectValue ?? [:]).compactMapValues { entry in
            guard let scope = entry["scope"]?.stringValue else { return nil }
            return Entry(scope: scope, opClass: entry["class"]?.stringValue ?? "read")
        }
        never = Set(json["never"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    /// The bundled table (empty when the resource is missing).
    public static let bundled: AppScopeTable = {
        guard let data = try? Data(contentsOf: AppPlatformResources.scopesFile) else { return AppScopeTable() }
        return (try? AppScopeTable(data: data)) ?? AppScopeTable()
    }()

    /// Why `op` with `params` is refused for an app holding `granted`, or
    /// nil when it may run. `net.fetch` needs a `net:` scope covering the
    /// URL's host; `integration.request` needs `integration:<provider>`
    /// (or its `:read` form for GET); `app.storage.*` is the app's own
    /// storage and always allowed.
    public func refusal(op: String, params: AppJSON, granted: Set<String>) -> AppOperationError? {
        if never.contains(op) {
            return AppOperationError(code: "operation.forbidden", message: "apps cannot call \(op)", details: ["op": .string(op)])
        }
        guard let entry = ops[op] else {
            return AppOperationError(code: "operation.unsupported", message: "unknown operation \(op)", details: ["op": .string(op)])
        }
        let needed: String
        switch entry.scope {
        case "storage:local":
            return nil
        case "net:<host>":
            guard let host = params["url"]?.stringValue.flatMap(URL.init(string:))?.host?.lowercased(),
                  params["url"]?.stringValue?.lowercased().hasPrefix("https://") == true else {
                return AppOperationError(code: "invalid_params", message: "net.fetch needs an https url", details: ["op": .string(op)])
            }
            if Self.netScopes(granted).contains(where: { Self.host(host, matches: $0) }) { return nil }
            needed = "net:\(host)"
        case "integration:<provider>":
            let provider = params["provider"]?.stringValue ?? ""
            let read = (params["method"]?.stringValue ?? "GET").uppercased() == "GET"
            if granted.contains("integration:\(provider)") || (read && granted.contains("integration:\(provider):read")) { return nil }
            needed = "integration:\(provider)\(read ? ":read" : "")"
        default:
            if granted.contains(entry.scope) { return nil }
            needed = entry.scope
        }
        return AppOperationError(code: "scope.missing", message: "this app does not hold \(needed)",
                                 details: ["scope": .string(needed), "op": .string(op)])
    }

    /// Whether `op` changes state (the host mints an idempotency key).
    public func isMutation(_ op: String) -> Bool { ops[op]?.opClass == "mutation" }

    /// Every op the grant allows (the runtime's `ops` init list). Ops whose
    /// scope depends on params are listed when the app holds any scope of
    /// that family, and checked again per call.
    public func allowedOps(granted: Set<String>) -> [String] {
        ops.filter { op, entry in
            if never.contains(op) { return false }
            switch entry.scope {
            case "storage:local": return true
            case "net:<host>": return !Self.netScopes(granted).isEmpty
            case "integration:<provider>": return granted.contains { $0.hasPrefix("integration:") }
            default: return granted.contains(entry.scope)
            }
        }.keys.sorted()
    }

    static func netScopes(_ granted: Set<String>) -> [String] {
        granted.filter { $0.hasPrefix("net:") }.map { String($0.dropFirst(4)).lowercased() }
    }

    /// `api.github.com` matches `api.github.com`; `*.example.com` matches
    /// any subdomain of example.com but not example.com itself.
    static func host(_ host: String, matches pattern: String) -> Bool {
        if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst(1))) }
        return host == pattern
    }
}
