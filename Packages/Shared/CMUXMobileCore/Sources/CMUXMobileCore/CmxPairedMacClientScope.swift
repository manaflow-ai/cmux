import Foundation

// lint:allow free-function — private, pure file-local tag canonicalization.
private func cmxCanonicalDevTag(_ rawValue: String?) -> String? {
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
    return String(decoding: bytes, as: UTF8.self)
}

// lint:allow free-function — private, pure file-local storage encoding.
private func cmxBase64URLComponent(_ value: String) -> String {
    Data(value.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

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

    private static let macDebugBundlePrefix = "com.cmuxterm.app.debug."

    /// Storage and wire identity for this build scope.
    ///
    /// Matchable scopes use their canonical tag. Non-matchable DEBUG iOS
    /// fallbacks use a reserved `ios-unmatched:` namespace that canonical tags
    /// cannot produce.
    public let value: String

    /// Canonical Mac tag this scope may discover, or `nil` when the iOS build
    /// has no trustworthy matching tag and must remain storage-only.
    public let matchingMacTag: String?

    /// Create a scope from a tag, canonicalized with the reload tooling's ASCII
    /// slug rules (lowercase, non-alphanumerics collapsed to `-`).
    ///
    /// `default` is reserved for untagged/stable presence records and is never a
    /// matchable DEV scope.
    public init?(_ rawValue: String?) {
        guard let tag = cmxCanonicalDevTag(rawValue), tag != "default" else { return nil }
        self.value = tag
        self.matchingMacTag = tag
    }

    private init(unmatchedIOSBundleIdentifier bundleIdentifier: String?) {
        let trimmedBundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let bundleIdentity = trimmedBundle.isEmpty ? "missing-bundle" : trimmedBundle
        self.value = "ios-unmatched:\(cmxBase64URLComponent(bundleIdentity))"
        self.matchingMacTag = nil
    }

    /// Resolve the tagged iOS bundle identity. Release/TestFlight bundles stay
    /// unscoped so their existing backup behavior is unchanged.
    public static func currentIOS(
        devTag: String?,
        bundleIdentifier: String?,
        isDebugBuild: Bool = false
    ) -> CmxPairedMacClientScope? {
        let prefix = "dev.cmux.ios."
        if let bundleIdentifier, bundleIdentifier.hasPrefix(prefix) {
            let suffix = String(bundleIdentifier.dropFirst(prefix.count))
            return CmxPairedMacClientScope(suffix)
                ?? CmxPairedMacClientScope(unmatchedIOSBundleIdentifier: bundleIdentifier)
        }

        if bundleIdentifier == "dev.cmux.ios" {
            return CmxPairedMacClientScope(devTag)
                ?? CmxPairedMacClientScope(unmatchedIOSBundleIdentifier: bundleIdentifier)
        }

        // Custom/manual DEBUG bundle identifiers cannot encode the canonical
        // tag in their suffix. Prefer CMUXDevTag, then use the deterministic
        // bundle-specific, non-matchable scope so every DEBUG build remains
        // isolated without ever treating stable tag `default` as its Mac.
        // Release and TestFlight callers pass false and therefore stay unscoped.
        guard isDebugBuild else { return nil }
        return CmxPairedMacClientScope(devTag)
            ?? CmxPairedMacClientScope(unmatchedIOSBundleIdentifier: bundleIdentifier)
    }

    /// Resolve a tagged Mac DEV bundle. Requiring the debug bundle family keeps
    /// a stray `CMUX_TAG` environment variable from partitioning stable builds.
    public static func currentMac(
        environment: [String: String],
        bundleIdentifier: String?
    ) -> CmxPairedMacClientScope? {
        let bundle = bundleIdentifier?.lowercased() ?? ""
        guard bundle.hasPrefix(Self.macDebugBundlePrefix) else { return nil }
        return CmxPairedMacClientScope(environment["CMUX_TAG"])
    }

    /// Filesystem/storage-safe encoding of the canonical build slug.
    public var storageComponent: String {
        cmxBase64URLComponent(value)
    }

    /// Versioned value sent in `X-Cmux-Client-Scope` and used for local storage.
    public var serializedScope: String {
        "\(Self.serializedPrefix)\(storageComponent)"
    }

    /// Whether a presence/registry instance belongs to this iOS build. Older
    /// presence records may omit the bundle id, so the exact dev tag is the
    /// authority; a supplied bundle id must still identify a Mac DEV build.
    public func matchesMacInstance(tag: String, bundleIdentifier: String?) -> Bool {
        guard let matchingMacTag,
              cmxCanonicalDevTag(tag) == matchingMacTag else { return false }
        let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return bundle.isEmpty || bundle.hasPrefix(Self.macDebugBundlePrefix)
    }
}
