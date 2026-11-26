internal import CmuxMobileSupport
import Foundation

extension MobileShellComposite {
    /// Build the host app version string shown in pairing/status diagnostics.
    static func mobileShellVersionDisplay(
        version: String?,
        build: String?,
        compatibilityVersion: Int?
    ) -> String {
        let version = version ?? mobileShellCompatibilityDisplay(compatibilityVersion)
        guard let build = mobileShellNormalizedNonEmpty(build) else { return version }
        return "\(version) (\(build))"
    }

    /// Return a localized compatibility fallback for Macs that do not report an app version.
    static func mobileShellCompatibilityDisplay(_ compatibilityVersion: Int?) -> String {
        guard let compatibilityVersion, compatibilityVersion > 0 else {
            return L10n.string(
                "mobile.pairing.compatibilityUnknown",
                defaultValue: "unknown compatibility"
            )
        }
        return String(
            format: L10n.string(
                "mobile.pairing.compatibilityDisplayFormat",
                defaultValue: "compatibility %@"
            ),
            "\(compatibilityVersion)"
        )
    }

    /// Normalize optional email values before comparing host-reported identity.
    static func mobileShellNormalizedEmail(_ value: String?) -> String? {
        mobileShellNormalizedNonEmpty(value)?.lowercased()
    }

    /// Trim optional strings and collapse blanks to nil.
    static func mobileShellNormalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
