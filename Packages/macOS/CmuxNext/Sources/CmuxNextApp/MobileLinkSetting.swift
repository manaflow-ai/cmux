import Foundation

/// Whether the cmux.mobile/1 phone link host runs next to the irx host
/// (d1-terminal-ux.md, Mac wiring). Default on in Debug (DEV) builds, off in
/// Release until D3 switches the phone over. Overrides, strongest first: the
/// environment (`CMUX_NEXT_MOBILE_LINK=1|0`, `CMUX_NEXT_MOBILE_LINK_WG=1|0`),
/// then the user defaults keys below. B3 (WireGuard over WebRTC) is a DEV
/// switch, default off everywhere.
struct MobileLinkSetting: Equatable {
    static let enabledKey = "cmuxNext.mobileLink.enabled"
    static let wireGuardKey = "cmuxNext.mobileLink.wireGuardOverWebRTC"

    var enabled: Bool
    var wireGuardOverWebRTC: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) {
        #if DEBUG
        let fallback = true
        #else
        let fallback = false
        #endif
        enabled = Self.flag(environment["CMUX_NEXT_MOBILE_LINK"]) ?? defaults.object(forKey: Self.enabledKey) as? Bool ?? fallback
        wireGuardOverWebRTC = Self.flag(environment["CMUX_NEXT_MOBILE_LINK_WG"])
            ?? defaults.object(forKey: Self.wireGuardKey) as? Bool ?? false
    }

    private static func flag(_ value: String?) -> Bool? {
        switch value {
        case "1", "true", "on": true
        case "0", "false", "off": false
        default: nil
        }
    }
}
