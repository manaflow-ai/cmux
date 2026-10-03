public import Foundation

/// The risk class of every app scope, read from `scope-classes.json`
/// (`cmux-tui/crates/cmux-app-host/schema/v2/scope-classes.json`, synced by
/// `scripts/cmux-next/sync-app-runtime.sh`). The Rust validator
/// (`cmux-app-manifest`) embeds the same file, so the consent sheet, the
/// permission policy and the validator cannot classify a scope differently.
/// Rules apply in order; the first match wins.
public nonisolated struct AppScopeClassTable: Sendable {
    /// How much review a scope needs before an app may hold it.
    public enum ScopeClass: String, Sendable, Hashable {
        /// Granted with the app; listed in Settings and revocable.
        case standard
        /// Highlighted on the consent sheet; revocable.
        case sensitive
        /// First-party apps, or Verified apps whose review covers the scope.
        case restricted
    }

    /// One rule of the table.
    public struct Rule: Sendable, Hashable {
        public var pattern: String
        public var scopeClass: ScopeClass
        /// Only an app server may hold the scope (`server.scopes`).
        public var serverOnly: Bool
    }

    public let rules: [Rule]

    /// The table bundled with this build; empty when the resource is missing
    /// or unreadable, so every scope is unclassified (and treated as
    /// restricted by ``isRestricted(_:)``) rather than silently allowed.
    public static let bundled = AppScopeClassTable(contentsOf: AppPlatformResources.scopeClassesFile)

    public init(rules: [Rule]) {
        self.rules = rules
    }

    public init(contentsOf url: URL) {
        self.init(data: (try? Data(contentsOf: url)) ?? Data())
    }

    public init(data: Data) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let rows = object?["rules"] as? [[String: Any]] ?? []
        rules = rows.compactMap { row in
            guard let pattern = row["pattern"] as? String,
                  let raw = row["class"] as? String, let scopeClass = ScopeClass(rawValue: raw) else { return nil }
            return Rule(pattern: pattern, scopeClass: scopeClass, serverOnly: row["serverOnly"] as? Bool ?? false)
        }
    }

    /// The first rule that matches `scope`, or nil when no rule knows it.
    public func rule(for scope: String) -> Rule? {
        let range = NSRange(scope.startIndex..., in: scope)
        return rules.first { rule in
            (try? NSRegularExpression(pattern: rule.pattern))?.firstMatch(in: scope, range: range) != nil
        }
    }

    /// The class of `scope`; nil when no rule knows it.
    public func scopeClass(of scope: String) -> ScopeClass? { rule(for: scope)?.scopeClass }

    /// Restricted, or unknown to the table (fail closed).
    public func isRestricted(_ scope: String) -> Bool { scopeClass(of: scope) ?? .restricted == .restricted }
}
