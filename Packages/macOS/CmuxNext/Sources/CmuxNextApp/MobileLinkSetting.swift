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

    static let allowedPortsKey = "cmuxNext.mobileLink.allowedPorts"
    static let vncKey = "cmuxNext.mobileLink.vnc"
    static let vncLoopbackKey = "cmuxNext.mobileLink.vncAllowLoopback"

    var enabled: Bool
    var wireGuardOverWebRTC: Bool
    /// C14: ports the user allows phones to forward besides detected dev servers (empty by default).
    var tunnelAllowedPorts: [UInt16]
    /// C3: whether phones may ask this Mac to dial VNC servers (off by default), and whether
    /// that includes this Mac's own loopback services (blocked by default).
    var vncEnabled: Bool
    var vncAllowsLoopback: Bool
    /// Spawn gates (b5-mac-host.md 3, c8-composer.md 3): off until the live
    /// check on a tagged build; DEV builds may turn them on for that check with
    /// `CMUX_NEXT_MOBILE_TASK_DISPATCH=1` / `CMUX_NEXT_MOBILE_TERMINAL_SPAWN=1`.
    var allowsTaskDispatch: Bool
    var allowsTerminalSpawn: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) {
        #if DEBUG
        let fallback = true
        #else
        let fallback = false
        #endif
        enabled = Self.flag(environment["CMUX_NEXT_MOBILE_LINK"]) ?? defaults.object(forKey: Self.enabledKey) as? Bool ?? fallback
        wireGuardOverWebRTC = Self.flag(environment["CMUX_NEXT_MOBILE_LINK_WG"])
            ?? defaults.object(forKey: Self.wireGuardKey) as? Bool ?? false
        tunnelAllowedPorts = (defaults.array(forKey: Self.allowedPortsKey) as? [Int] ?? [])
            .compactMap { UInt16(exactly: $0) }.filter { $0 >= 1024 }
        vncEnabled = defaults.object(forKey: Self.vncKey) as? Bool ?? false
        vncAllowsLoopback = defaults.object(forKey: Self.vncLoopbackKey) as? Bool ?? false
        #if DEBUG
        allowsTaskDispatch = Self.flag(environment["CMUX_NEXT_MOBILE_TASK_DISPATCH"]) ?? false
        allowsTerminalSpawn = Self.flag(environment["CMUX_NEXT_MOBILE_TERMINAL_SPAWN"]) ?? false
        #else
        allowsTaskDispatch = false
        allowsTerminalSpawn = false
        #endif
    }

    private static func flag(_ value: String?) -> Bool? {
        switch value {
        case "1", "true", "on": true
        case "0", "false", "off": false
        default: nil
        }
    }
}
