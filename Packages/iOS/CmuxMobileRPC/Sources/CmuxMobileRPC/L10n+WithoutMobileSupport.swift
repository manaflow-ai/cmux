#if !canImport(CmuxMobileSupport)
internal import CMUXMobileCore
internal import Foundation

/// The one `CmuxMobileSupport.L10n` call this target makes, for builds that
/// leave that UIKit package out (the Linux package jobs, which set
/// CMUX_SWIFTPM_TARGET_LINUX). It resolves the same way: the key through
/// `Bundle.main`, falling back to `defaultValue`. Apple builds keep the real
/// `L10n` and never compile this file's body.
struct L10n {
    package init() {}
    static func string(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .main)
    }
}
#endif
