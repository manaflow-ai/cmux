public import CmuxNextDaemon

/// Identity and feature set a cmux-next Mac reports in `mobile.host.status`.
///
/// Shipped official iOS builds accept only tags `default`, `nightly`, `rc`
/// and the matching `mac:com.cmuxterm.app*` namespaces; DEBUG phones need
/// the exact dev tag and a `mac:com.cmuxterm.app.debug*` namespace. Tagged
/// cmux-next builds use the same bundle id scheme as the old app, so the
/// values below come straight from the bundle and tag.
public struct MobileCompatHostInfo: Sendable {
    /// Capability that tells a new phone it may open an irx `daemon` lane.
    public static let daemonLaneCapability = "daemon_lane.v1"

    public var macDeviceID: String
    public var instanceTag: String
    public var bundleIdentifier: String
    public var displayName: String
    public var appVersion: String
    public var appBuild: String
    public var daemonLaneAvailable: Bool

    public init(macDeviceID: String, instanceTag: String, bundleIdentifier: String, displayName: String,
                appVersion: String, appBuild: String, daemonLaneAvailable: Bool) {
        self.macDeviceID = macDeviceID
        self.instanceTag = instanceTag
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.daemonLaneAvailable = daemonLaneAvailable
    }

    /// What the compat adapter actually serves. The phone gates features on
    /// these, so nothing is listed that would fail on first use. No
    /// `terminal.render_grid*` and no `terminal_fidelity`: the phone then runs
    /// raw-bytes mode, fed by the daemon's complete vt-state replay.
    public var capabilities: [String] {
        var list = [
            "events.v1",
            "terminal.bytes.v1",
            "terminal.replay.v1",
            "terminal.viewport.v1",
            "workspace.actions.v1",
            "workspace.close.v1",
            "workspace.groups.v1",
            "workspace.mutations.account_auth.v1",
        ]
        if daemonLaneAvailable { list.append(Self.daemonLaneCapability) }
        return list
    }

    var statusPayload: JSONValue {
        .object([
            "capabilities": .strings(capabilities),
            "mac_display_name": .string(displayName),
            "mac_device_id": .string(macDeviceID),
            "mac_instance_tag": .string(instanceTag),
            "mac_client_namespace": .string("mac:\(bundleIdentifier)"),
            "mac_compatible_mac_tags": .array([]),
            "mac_app_version": .string(appVersion),
            "mac_app_build": .string(appBuild),
        ])
    }
}
