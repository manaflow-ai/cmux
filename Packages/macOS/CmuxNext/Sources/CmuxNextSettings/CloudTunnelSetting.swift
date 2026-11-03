/// The opt-in Cloud Tunnel in cmux.json: a system-wide route from this Mac to the person's Cloud
/// machines, for apps other than cmux (Safari, VS Code, `ssh` in Terminal).
///
/// ```jsonc
/// "cloud": { "tunnel": { "enabled": true } }
/// ```
///
/// Off by default. Turning it on installs the cmux Cloud Tunnel network extension (macOS asks once
/// in System Settings) and starts it; off stops it. cmux's own terminals, browser and Desktop never
/// need it (plans/cmux-next/cloud-tunnel-DESIGN.md).
public nonisolated struct CloudTunnelSetting: Sendable {
    public static let enabledPath = ["cloud", "tunnel", "enabled"]

    public init() {}

    /// Whether the tunnel is on; a missing or non-boolean value is off.
    public func enabled(in root: JSONValue) -> Bool {
        root.value(at: Self.enabledPath)?.boolValue ?? false
    }

    static var descriptors: [SettingDescriptor] {
        [
            SettingDescriptor(
                enabledPath, section: .machines,
                group: SettingsText.keyed("settings.group.cloudTunnel", "Cloud Tunnel"),
                title: SettingsText.keyed("settings.cloud.tunnel.enabled", "Cloud Tunnel"),
                help: SettingsText.keyed("settings.cloud.tunnel.enabled.help",
                                         "Lets every app on this Mac reach your Cloud machines' private addresses, like a VPN for your Cloud network only. macOS asks you to allow the cmux network extension once. cmux itself does not need it."),
                kind: .toggle, default: .bool(false),
                keywords: ["cloud", "tunnel", "vpn", "wireguard", "network extension", "private network", "ssh", "machine", "toggle"]
            ),
        ]
    }
}
