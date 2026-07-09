public import CMUXMobileCore
public import Foundation

/// Identifies the running iOS app build for local paired-Mac scoping.
///
/// Tagged DEBUG installs have distinct bundle ids and home-screen labels.
/// Storage follows the installed bundle suffix so equivalent raw tags that
/// sanitize to the same bundle id also share the same saved-Mac scope. Release
/// builds intentionally return `nil` so they keep the stable, unscoped saved-Mac
/// list.
public typealias MobileIOSBuildScope = CmxPairedMacClientScope

public extension CmxPairedMacClientScope {
    /// Resolve the running iOS app's strict DEV build scope.
    static func current(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> MobileIOSBuildScope? {
        currentIOS(
            devTag: infoDictionary?["CMUXDevTag"] as? String,
            bundleIdentifier: bundleIdentifier
        )
    }
}
