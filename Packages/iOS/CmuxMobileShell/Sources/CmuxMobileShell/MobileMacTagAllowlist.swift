public import Foundation

/// The runtime-mutable set of additional Mac development tags one development
/// iOS build may use beyond its own tag.
///
/// One instance is created at app launch and shared by reference through
/// ``MobileMacBuildCompatibilityPolicy``, so persistence scoping, registry and
/// presence projection, discovery filtering, and live connection validation
/// all read the same grant set: a mutation is visible to every consumer on its
/// next policy evaluation, without re-plumbing the composition graph.
///
/// The set is granted at runtime by this build's exact-tag Mac (over the
/// authenticated control connection) rather than baked in at compile time, and
/// it persists across launches in the tagged bundle's own `UserDefaults`.
public final class MobileMacTagAllowlist: @unchecked Sendable {
    /// Bounds a hostile or runaway grant set; discovery admission is already
    /// bounded per pass, so this only caps persistence and filtering cost.
    public static let maximumTagCount = 32

    /// The tagged iOS bundle id already isolates `UserDefaults` per build
    /// scope, so one fixed key is per-tag by construction.
    public static let defaultsKey = "CMUXCompatibleMacTags"

    private let lock = NSLock()
    private var storage: Set<String>
    private let defaults: UserDefaults?

    /// An in-memory allowlist. Used by tests and as the empty default.
    public init(tags: some Sequence<String> = [String]()) {
        storage = Self.sanitized(tags)
        defaults = nil
    }

    private init(defaults: UserDefaults) {
        let persistedTags = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        storage = Self.sanitized(persistedTags)
        self.defaults = defaults
    }

    /// The allowlist persisted for this app install, loading any grant set a
    /// previous launch stored.
    public static func persisted(
        defaults: UserDefaults = .standard
    ) -> MobileMacTagAllowlist {
        MobileMacTagAllowlist(defaults: defaults)
    }

    /// Whether a normalized Mac instance tag is granted by this allowlist.
    public func contains(normalizedTag: String) -> Bool {
        lock.withLock { storage.contains(normalizedTag) }
    }

    /// A point-in-time copy of the granted tags.
    public var tags: Set<String> {
        lock.withLock { storage }
    }

    /// Replaces the grant set, returning whether anything changed. Input is
    /// normalized, deduplicated, capped, and stripped of release-lane tags
    /// before comparison, so a semantically identical advertisement is a no-op.
    @discardableResult
    public func replace(with tags: some Sequence<String>) -> Bool {
        let sanitized = Self.sanitized(tags)
        let changed: Bool = lock.withLock {
            guard storage != sanitized else { return false }
            storage = sanitized
            return true
        }
        guard changed else { return false }
        defaults?.set(sanitized.sorted(), forKey: Self.defaultsKey)
        return true
    }

    /// Trim-and-lowercase tag normalization shared with the compatibility
    /// policy, so grant comparison and policy checks can never disagree.
    public static func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private static func sanitized(_ tags: some Sequence<String>) -> Set<String> {
        var sanitized: Set<String> = []
        for tag in tags {
            guard let normalized = normalized(tag),
                  !MobileMacBuildCompatibilityPolicy.isNonDevelopmentTag(normalized)
            else { continue }
            sanitized.insert(normalized)
            if sanitized.count == maximumTagCount { break }
        }
        return sanitized
    }
}
