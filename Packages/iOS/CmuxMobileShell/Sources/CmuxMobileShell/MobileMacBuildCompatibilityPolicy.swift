public import CMUXMobileCore
public import CmuxMobilePairedMac
internal import Foundation

/// Defines which authenticated Mac app instances one iOS app build may use.
///
/// Mac app identity remains exact (`default`, `nightly`, or a development tag),
/// while this policy supplies the compatibility boundary used by persistence,
/// registry projection, and live connection validation.
public enum MobileMacBuildCompatibilityPolicy: Equatable, Sendable {
    /// A tagged development build may use only the matching Mac development tag.
    case development(expectedInstanceTag: String)
    /// A distributed iOS build may use Stable and Nightly Mac releases.
    case official

    /// Resolves the policy compiled into the running iOS app.
    ///
    /// - Parameter buildScope: The tagged development scope, when this is a
    ///   tagged DEBUG build.
    /// - Returns: Exact-tag development compatibility for DEBUG builds and
    ///   official compatibility for distributed builds.
    public static func current(
        buildScope: MobileIOSBuildScope?
    ) -> MobileMacBuildCompatibilityPolicy {
        #if DEBUG
        return .development(expectedInstanceTag: buildScope?.value ?? "dev")
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
        case .development(let expectedInstanceTag):
            return normalizedTag == Self.normalized(expectedInstanceTag)
        case .official:
            return normalizedTag == "default" || normalizedTag == "nightly"
        }
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
