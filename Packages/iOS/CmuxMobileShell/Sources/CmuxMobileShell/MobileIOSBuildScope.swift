public import CMUXMobileCore
public import Foundation

#if DEBUG
private let mobileIOSIsDebugBuild = true
#else
private let mobileIOSIsDebugBuild = false
#endif

/// Identifies the running iOS app build for local paired-Mac scoping.
///
/// Tagged DEBUG installs have distinct bundle ids and home-screen labels.
/// Storage follows the installed bundle suffix so equivalent raw tags that
/// sanitize to the same bundle id also share the same saved-Mac scope. Release
/// builds intentionally return `nil` so they keep the stable, unscoped saved-Mac
/// list.
public typealias MobileIOSBuildScope = CmxPairedMacClientScope

/// iOS composition helpers for resolving the running build's shared client scope.
public extension CmxPairedMacClientScope {
    /// Resolve the running iOS app's strict DEV build scope.
    static func current(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool? = nil
    ) -> MobileIOSBuildScope? {
        currentIOS(
            devTag: infoDictionary?["CMUXDevTag"] as? String,
            bundleIdentifier: bundleIdentifier,
            isDebugBuild: isDebugBuild ?? mobileIOSIsDebugBuild
        )
    }
}
