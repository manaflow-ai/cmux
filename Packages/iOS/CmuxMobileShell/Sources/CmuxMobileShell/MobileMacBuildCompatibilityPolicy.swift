public import CMUXMobileCore
public import CmuxMobilePairedMac
internal import Foundation

/// Defines which authenticated Mac app instances one iOS app build may use.
///
/// Mac app identity remains exact (`default`, `nightly`, or a development tag),
/// while this policy supplies the compatibility boundary used by persistence,
/// registry projection, and live connection validation.
public enum MobileMacBuildCompatibilityPolicy: Equatable, Sendable {
    /// A tagged development build may use its matching Mac tag plus an explicit
    /// set of sibling tags baked into that build. The additional set is empty by
    /// default, preserving per-tag isolation for ordinary development builds.
    case development(
        expectedInstanceTag: String,
        additionalInstanceTags: Set<String>
    )
    /// A distributed iOS build may use Stable and Nightly Mac releases.
    case official

    public static func development(
        expectedInstanceTag: String
    ) -> MobileMacBuildCompatibilityPolicy {
        .development(
            expectedInstanceTag: expectedInstanceTag,
            additionalInstanceTags: []
        )
    }

    /// Resolves the policy compiled into the running iOS app.
    ///
    /// - Parameters:
    ///   - buildScope: The tagged development scope, when this is a tagged DEBUG build.
    ///   - compatibleMacTags: Comma-separated sibling Mac tags intentionally
    ///     admitted by this development build.
    /// - Returns: Explicit development compatibility for DEBUG builds and official
    ///   compatibility for distributed builds.
    public static func current(
        buildScope: MobileIOSBuildScope?,
        compatibleMacTags: String? = nil
    ) -> MobileMacBuildCompatibilityPolicy {
        #if DEBUG
        let additionalTags = Set((compatibleMacTags ?? "")
            .split(separator: ",")
            .map(String.init))
        return .development(
            expectedInstanceTag: buildScope?.value ?? "dev",
            additionalInstanceTags: additionalTags
        )
        #else
        return .official
        #endif
    }

    /// Returns whether an authenticated Mac instance belongs to this policy.
    ///
    /// Missing tags fail closed because they cannot distinguish two app
    /// instances on the same physical Mac.
    ///
    /// - Parameter instanceTag: The tag reported by authenticated host status.
    /// - Returns: `true` only when the Mac instance is compatible.
    public func allows(instanceTag: String?) -> Bool {
        guard let normalizedTag = Self.normalized(instanceTag) else { return false }
        switch self {
        case let .development(expectedInstanceTag, additionalInstanceTags):
            if normalizedTag == Self.normalized(expectedInstanceTag) {
                return true
            }
            return additionalInstanceTags.contains {
                normalizedTag == Self.normalized($0)
            }
        case .official:
            return normalizedTag == "default" || normalizedTag == "nightly"
        }
    }

    /// Returns whether authenticated host status is compatible with this build.
    ///
    /// cmux 0.64.17 predates the authenticated instance-tag field. Distributed
    /// iOS builds may retain that one legacy release only when the user has
    /// authorized the exact private endpoint locally. Discovery and route
    /// admission stay fail-closed, as do development builds and newer untagged
    /// Mac releases.
    public func allowsAuthenticatedHost(
        instanceTag: String?,
        macAppVersion: String?,
        usesLocallyAuthorizedTailscaleRoute: Bool
    ) -> Bool {
        if allows(instanceTag: instanceTag) {
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

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}
