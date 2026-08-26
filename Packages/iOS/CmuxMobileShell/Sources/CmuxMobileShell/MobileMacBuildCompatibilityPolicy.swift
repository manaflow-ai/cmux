public import CMUXMobileCore
public import CmuxMobilePairedMac
internal import Foundation

/// Defines which authenticated Mac app instances one iOS app build may use.
///
/// Mac app identity remains exact (`default`, `nightly`, or a development tag),
/// while this policy supplies the compatibility boundary used by persistence,
/// registry projection, and live connection validation.
public enum MobileMacBuildCompatibilityPolicy: Equatable, Sendable {
    private static let nonDevelopmentTags: Set<String> = [
        "default",
        "nightly",
        "rc",
        "staging",
    ]

    /// A tagged development build may use its matching Mac tag plus the tags in
    /// its runtime allowlist. The allowlist starts empty, preserving per-tag
    /// isolation for ordinary development builds; this build's exact-tag Mac
    /// grants additional tags at runtime (`cmux mobile compatible-tags`),
    /// which mutates the shared allowlist reference in place so every policy
    /// consumer sees the change without recomposition.
    case development(
        expectedInstanceTag: String,
        additionalInstanceTags: MobileMacTagAllowlist
    )
    /// A distributed iOS build may use Stable and Nightly Mac releases.
    case official

    public static func development(
        expectedInstanceTag: String
    ) -> MobileMacBuildCompatibilityPolicy {
        .development(
            expectedInstanceTag: expectedInstanceTag,
            additionalInstanceTags: MobileMacTagAllowlist()
        )
    }

    /// Resolves the policy compiled into the running iOS app.
    ///
    /// - Parameters:
    ///   - buildScope: The tagged development scope, when this is a tagged DEBUG build.
    ///   - additionalInstanceTags: The runtime-granted sibling Mac tags this
    ///     development build may also use.
    /// - Returns: Explicit development compatibility for DEBUG builds and official
    ///   compatibility for distributed builds.
    public static func current(
        buildScope: MobileIOSBuildScope?,
        additionalInstanceTags: MobileMacTagAllowlist = MobileMacTagAllowlist()
    ) -> MobileMacBuildCompatibilityPolicy {
        #if DEBUG
        return .development(
            expectedInstanceTag: buildScope?.value ?? "dev",
            additionalInstanceTags: additionalInstanceTags
        )
        #else
        return .official
        #endif
    }

    /// The runtime allowlist backing a development policy, for the grant
    /// application path. `nil` for distributed builds.
    public var developmentAdditionalInstanceTags: MobileMacTagAllowlist? {
        guard case let .development(_, additionalInstanceTags) = self else {
            return nil
        }
        return additionalInstanceTags
    }

    /// The exact Mac tag a development policy is bound to. `nil` for
    /// distributed builds.
    public var developmentExpectedInstanceTag: String? {
        guard case let .development(expectedInstanceTag, _) = self else {
            return nil
        }
        return expectedInstanceTag
    }

    /// Whether a normalized tag names a release lane no development build may
    /// use or grant.
    public static func isNonDevelopmentTag(_ normalizedTag: String) -> Bool {
        nonDevelopmentTags.contains(normalizedTag)
    }

    /// Returns whether an authenticated Mac instance belongs to this policy.
    ///
    /// Missing tags fail closed because they cannot distinguish two app
    /// instances on the same physical Mac.
    ///
    /// - Parameter instanceTag: The tag reported by authenticated host status.
    /// - Returns: `true` only when the Mac instance is compatible.
    public func allows(
        instanceTag: String?,
        clientNamespace: String? = nil
    ) -> Bool {
        guard let normalizedTag = Self.normalized(instanceTag) else { return false }
        switch self {
        case let .development(expectedInstanceTag, additionalInstanceTags):
            if let clientNamespace,
               clientNamespace != "legacy",
               !Self.isDevelopmentMacNamespace(clientNamespace) {
                return false
            }
            guard !Self.nonDevelopmentTags.contains(normalizedTag) else {
                return false
            }
            if normalizedTag == Self.normalized(expectedInstanceTag) {
                return true
            }
            return additionalInstanceTags.contains(normalizedTag: normalizedTag)
        case .official:
            if let clientNamespace,
               clientNamespace != "legacy",
               !Self.isOfficialMacNamespace(clientNamespace) {
                return false
            }
            return normalizedTag == "default" || normalizedTag == "nightly"
        }
    }

    private static func isDevelopmentMacNamespace(_ value: String) -> Bool {
        value == "mac:com.cmuxterm.app.debug"
            || value.hasPrefix("mac:com.cmuxterm.app.debug.")
    }

    private static func isOfficialMacNamespace(_ value: String) -> Bool {
        value == "mac:com.cmuxterm.app"
            || value == "mac:com.cmuxterm.app.nightly"
            || value.hasPrefix("mac:com.cmuxterm.app.nightly.")
    }

    /// Returns whether authenticated host status is compatible with this build.
    ///
    /// cmux 0.64.17 predates the authenticated instance-tag field. Distributed
    /// iOS builds may retain that one legacy release only when the user has
    /// authorized the exact Tailscale endpoint locally. Discovery and Iroh stay
    /// fail-closed, as do development builds and newer untagged Mac releases.
    public func allowsAuthenticatedHost(
        instanceTag: String?,
        clientNamespace: String? = nil,
        macAppVersion: String?,
        usesLocallyAuthorizedTailscaleRoute: Bool
    ) -> Bool {
        if case .development = self, clientNamespace == nil {
            // Direct pairing has no broker binding to supply the Mac bundle
            // namespace. Require host status to carry it so manual and QR
            // routes enforce the same channel boundary as discovery.
            return false
        }
        if allows(instanceTag: instanceTag, clientNamespace: clientNamespace) {
            return true
        }
        guard case .official = self,
              Self.normalized(instanceTag) == nil,
              usesLocallyAuthorizedTailscaleRoute,
              let rawVersion = macAppVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              let version = MobileMacAppVersion(parsing: rawVersion),
              let legacyMinimum = MobileMacAppVersion(parsing: "0.64.17"),
              let firstTaggedRelease = MobileMacAppVersion(parsing: "0.64.18")
        else {
            return false
        }
        return version >= legacyMinimum && version < firstTaggedRelease
    }

    /// Wraps a paired-Mac store so every read and mutation follows this policy.
    ///
    /// - Parameter store: The underlying persistence implementation.
    /// - Returns: A store that hides and rejects incompatible app instances.
    public func scoping(
        _ store: any MobilePairedMacStoring
    ) -> any MobilePairedMacStoring {
        MobileMacCompatiblePairedMacStore(inner: store, policy: self)
    }

    /// Two development policies are equal when they enforce the same expected
    /// tag against the same live allowlist instance. Identity (not contents)
    /// is deliberate: the allowlist mutates at runtime, and equality by
    /// snapshot would let two policies compare equal now and diverge later.
    public static func == (
        lhs: MobileMacBuildCompatibilityPolicy,
        rhs: MobileMacBuildCompatibilityPolicy
    ) -> Bool {
        switch (lhs, rhs) {
        case let (
            .development(lhsTag, lhsAllowlist),
            .development(rhsTag, rhsAllowlist)
        ):
            return normalized(lhsTag) == normalized(rhsTag)
                && lhsAllowlist === rhsAllowlist
        case (.official, .official):
            return true
        default:
            return false
        }
    }

    private static func normalized(_ value: String?) -> String? {
        MobileMacTagAllowlist.normalized(value)
    }
}
