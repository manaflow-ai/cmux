import CmuxNextApps
import Foundation

/// The parsed parts of a scope string and its classification.
public nonisolated struct AppScopeKind: Sendable, Hashable {
    public var scope: String
    /// `workspace`, `net`, `integration`, `fs`, ...
    public var family: String
    /// `read`, `write`, `execute`, ... or the host / provider for `net:` and `integration:`.
    public var level: String
    public var risk: AppScopeRisk
    public var axis: AppScopeAxis

    public init(_ scope: String) {
        self.scope = scope
        let parts = scope.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        family = parts.first ?? scope
        level = parts.count > 1 ? parts[1] : ""
        (risk, axis) = Self.classify(family: family, level: level)
    }

    /// Scopes only first-party apps (and Verified versions whose human
    /// review approved them) may hold: the `restricted` class of the shared
    /// scope table (`AppScopeClassTable`, the Rust validator's table), and any
    /// scope the table does not know. `fs:write:<root>` counts as `fs:write`.
    public var isRestricted: Bool {
        let base = family == "fs" ? "fs:" + (level.split(separator: ":").first.map(String.init) ?? level) : scope
        return AppScopeClassTable.bundled.isRestricted(base)
    }

    /// Granted only by an explicit user grant in the native confirmation
    /// sheet, never at install (`elevated` in the shared scope table).
    public var isElevated: Bool { AppScopeClassTable.bundled.isElevated(scope) }

    /// A network host scope (`net:api.example.com`, `net:*.example.com`).
    public var isNetwork: Bool { family == "net" }
    /// A file scope (`fs:read`, `fs:write`, `fs:read:<root>`).
    public var isFiles: Bool { family == "fs" }
    /// The host of a `net:` scope.
    public var host: String? { isNetwork ? level.lowercased() : nil }

    private static func classify(family: String, level: String) -> (AppScopeRisk, AppScopeAxis) {
        switch family {
        case "net":
            return (.network, .network)
        case "integration":
            return (level.hasSuffix(":read") ? .read : .external, .network)
        case "fs":
            return (level.hasPrefix("read") ? .read : .write, .files)
        case "mcp":
            return (.write, .agents)
        case "clipboard":
            return (.write, .clipboard)
        case "notification":
            return (level == "read" ? .read : .write, .notifications)
        case "storage":
            return (level == "local" ? .read : .write, .storage)
        case "coderouter" where level == "keys":
            return (.external, .operations)
        default:
            switch level {
            case "read": return (.read, .operations)
            case "write", "post": return (.write, .operations)
            case "execute", "run", "input", "control": return (.execute, .processes)
            case "external": return (.external, .operations)
            default: return (.write, .operations)
            }
        }
    }
}
