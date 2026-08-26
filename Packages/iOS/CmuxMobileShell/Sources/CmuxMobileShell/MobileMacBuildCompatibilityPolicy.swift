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

    /// A development iOS build may use any authenticated development Mac tag.
    /// The exact tag remains part of each Mac's identity; this case only defines
    /// the development build lane.
    case development
    /// A distributed iOS build may use Stable and Nightly Mac releases.
    case official

    /// Resolves the policy compiled into the running iOS app.
    ///
    /// - Returns: Development-lane compatibility for DEBUG builds and official
    ///   compatibility for distributed builds.
    public static func current() -> MobileMacBuildCompatibilityPolicy {
        #if DEBUG
        return .development
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
    public func allows(
        instanceTag: String?,
        clientNamespace: String? = nil
    ) -> Bool {
        guard let normalizedTag = Self.normalized(instanceTag) else { return false }
        switch self {
        case .development:
            if let clientNamespace,
               clientNamespace != "legacy",
               !Self.isDevelopmentMacNamespace(clientNamespace) {
                return false
            }
            return !Self.nonDevelopmentTags.contains(normalizedTag)
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
    /// authorized the exact Tailscale endpoint locally. Everything else stays
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

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}
