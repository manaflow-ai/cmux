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

    /// Worker endpoint that understands strict build scopes without seeding
    /// them from legacy unscoped state. Older workers do not expose this path,
    /// so strict clients fail closed with 404 during a staggered rollout.
    public static let pairedMacBackupPath = "/v2/sync/paired-macs"

    /// Canonical tagged-build slug shared by the Mac and iOS bundle.
    public let value: String

    /// Create a scope from a tag, canonicalized with the reload tooling's ASCII
    /// slug rules (lowercase, non-alphanumerics collapsed to `-`).
    ///
    /// `default` is a valid explicit dev tag. Stable builds stay unscoped by
    /// failing the bundle-family checks in ``currentIOS(devTag:bundleIdentifier:)``
    /// and ``currentMac(environment:bundleIdentifier:)``, not through a tag-value
    /// sentinel that could make a tagged build silently share stable state.
    public init?(_ rawValue: String?) {
        var bytes: [UInt8] = []
        for scalar in (rawValue ?? "").unicodeScalars {
            let byte: UInt8
            switch scalar.value {
            case 48...57, 97...122:
                byte = UInt8(scalar.value)
            case 65...90:
                byte = UInt8(scalar.value + 32)
            default:
                if !bytes.isEmpty, bytes.last != 45 {
                    bytes.append(45)
                }
                continue
            }
            bytes.append(byte)
        }
        while bytes.last == 45 {
            bytes.removeLast()
        }
        guard !bytes.isEmpty else { return nil }
        self.value = String(decoding: bytes, as: UTF8.self)
    }

    /// Resolve the tagged iOS bundle identity. Release/TestFlight bundles stay
    /// unscoped so their existing backup behavior is unchanged.
    public static func currentIOS(
        devTag: String?,
        bundleIdentifier: String?,
        isDebugBuild: Bool = false
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

        // Custom/manual DEBUG bundle identifiers cannot encode the canonical
        // tag in their suffix. Prefer CMUXDevTag, then use the deterministic
        // default scope so every DEBUG build remains isolated. Release and
        // TestFlight callers pass false and therefore stay unscoped.
        guard isDebugBuild else { return nil }
        return CmxPairedMacClientScope(devTag) ?? CmxPairedMacClientScope("default")
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
        guard CmxPairedMacClientScope(tag)?.value == value else { return false }
        let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return bundle.isEmpty || bundle.hasPrefix("com.cmuxterm.app.debug.")
    }
}
