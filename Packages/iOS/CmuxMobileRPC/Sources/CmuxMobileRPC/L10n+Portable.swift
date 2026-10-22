#if !canImport(CmuxMobileSupport)
internal import CMUXMobileCore
internal import Foundation

/// The `L10n.string` lookup of CmuxMobileSupport, for builds without that
/// package: its SwiftUI views do not build on Linux, so the Linux package job
/// drops the dependency. Strings resolve through `Bundle.main` as there.
// lint:allow namespace-enum - stands in for CmuxMobileSupport.L10n so the call sites build unchanged.
enum L10n {
    static func string(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .main)
    }
}
#endif
