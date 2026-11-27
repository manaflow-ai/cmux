public import Foundation

/// Developer tools (Debug Settings and other `isDebugOnly` actions) exist in
/// DEV builds (a Debug compile, `com.cmuxterm.app.debug[.<tag>]`) and in
/// NIGHTLY builds (`com.cmuxterm.app.nightly[.<tag>]`). Release and RC
/// builds never offer them: the actions are unavailable in every surface
/// and the tunable store never activates, so every tunable keeps its code
/// default.
///
/// NIGHTLY compiles in the Release configuration like Release and RC, so a
/// compile-time `#if DEBUG` cannot tell them apart; the bundle identifier
/// can, and a promoted RC or stable build carries its own identifier.
public nonisolated enum DevTools {
    public static let nightlyBundleID = "com.cmuxterm.app.nightly"

    /// Pure rule, for tests: a Debug compile, or a nightly bundle (tagged
    /// or not).
    public static func isAvailable(bundleID: String?, isDebugBuild: Bool) -> Bool {
        if isDebugBuild { return true }
        guard let bundle = bundleID?.trimmingCharacters(in: .whitespaces) else { return false }
        return bundle == nightlyBundleID || bundle.hasPrefix(nightlyBundleID + ".")
    }

    /// Whether this compile is a Debug build.
    public static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// This process: decided once from its own bundle.
    public static let isEnabled = isAvailable(bundleID: Bundle.main.bundleIdentifier, isDebugBuild: isDebugBuild)
}
