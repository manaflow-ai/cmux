import Foundation

/// Versioned client scope shared by a tagged Mac build and its matching iOS
/// build. The wire value partitions paired-Mac backup state on the presence
/// worker; the same value also partitions iOS local storage.
///
/// Version 2 is intentionally a fresh namespace. Version 1 tagged iOS scopes
/// were seeded from the unscoped Release backup, so they can contain computers
/// from unrelated dev builds. Moving both clients to this strict namespace
/// leaves that contaminated state behind without deleting Release backups.
public struct CmxPairedMacClientScope: Sendable, Equatable, Hashable {
    /// Wire prefix for the strict paired-Mac backup protocol version.
    public static let serializedPrefix = "cmux-dev:v2:"

    /// Canonical tagged-build slug shared by the Mac and iOS bundle.
    public let value: String

    /// Create a scope from a nonempty, non-default tagged-build slug.
    public init?(_ rawValue: String?) {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "default" else { return nil }
        self.value = trimmed
    }

    /// Resolve the tagged iOS bundle identity. Release/TestFlight bundles stay
    /// unscoped so their existing backup behavior is unchanged.
    public static func currentIOS(
        devTag: String?,
        bundleIdentifier: String?
    ) -> CmxPairedMacClientScope? {
        let prefix = "dev.cmux.ios."
        if let bundleIdentifier,
           bundleIdentifier.hasPrefix(prefix),
           let scope = CmxPairedMacClientScope(String(bundleIdentifier.dropFirst(prefix.count))) {
            return scope
        }

        if bundleIdentifier == "dev.cmux.ios",
           let scope = CmxPairedMacClientScope(devTag) {
            return scope
        }

        return nil
    }

    /// Resolve a tagged Mac DEV bundle. Requiring the debug bundle family keeps
    /// a stray `CMUX_TAG` environment variable from partitioning stable builds.
    public static func currentMac(
        environment: [String: String],
        bundleIdentifier: String?
    ) -> CmxPairedMacClientScope? {
        let bundle = bundleIdentifier?.lowercased() ?? ""
        guard bundle.hasPrefix("com.cmuxterm.app.debug.") else { return nil }
        return CmxPairedMacClientScope(environment["CMUX_TAG"])
    }

    /// Filesystem/storage-safe encoding of the canonical build slug.
    public var storageComponent: String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Versioned value sent in `X-Cmux-Client-Scope` and used for local storage.
    public var serializedScope: String {
        "\(Self.serializedPrefix)\(storageComponent)"
    }

    /// Whether a presence/registry instance belongs to this iOS build. Older
    /// presence records may omit the bundle id, so the exact dev tag is the
    /// authority; a supplied bundle id must still identify a Mac DEV build.
    public func matchesMacInstance(tag: String, bundleIdentifier: String?) -> Bool {
        guard tag.trimmingCharacters(in: .whitespacesAndNewlines) == value else { return false }
        let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return bundle.isEmpty || bundle.hasPrefix("com.cmuxterm.app.debug.")
    }
}
