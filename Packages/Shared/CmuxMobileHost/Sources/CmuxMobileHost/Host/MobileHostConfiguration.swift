public import CmuxMobileWire

/// Static inputs of one Mac host.
public struct MobileHostConfiguration: Sendable {
    /// This Mac's host id (`h_…`, the id `HostDO` and the proof name).
    public var hostID: String
    /// The account user the Mac is signed into; only its devices are admitted.
    public var accountUserID: String
    /// Off until a live verification shows phone-created terminals run here as
    /// the login shell with no phone input in argv, cwd or env.
    public var allowsTerminalSpawn: Bool
    /// Off until a live verification shows a phone-dispatched agent session runs
    /// here as the user, in the workspace's own directory, with no phone text in
    /// its argv, cwd or env and the prompt delivered verbatim as the first user
    /// message (c8-composer.md section 3). Gates `task.dispatch`.
    public var allowsTaskDispatch: Bool
    /// `hello.ok.max_frame`.
    public var maxFrame: Int
    /// Caps this host offers in `hello.ok` (intersected with the client's).
    public var caps: [String]
    /// Metadata returned by the authenticated `mobile.host.status` read.
    /// These values are deliberately carried by the host configuration so the
    /// phone does not have to trust a discovery record for compatibility UI.
    public var displayName: String
    public var appVersion: String
    public var appBuild: String

    /// `workspace.close`, `workspace.read` and `workspace.preview` tell the
    /// phone it may offer Close and Mark as Read and that rows carry preview
    /// lines (c5-workspaces.md section 2); they also go up in `host.caps.set`.
    /// `workspace.move`, `workspace.group.rename` and `workspace.customize`
    /// offer drag reorder, group rename and the customize sheet (E3).
    public static let defaultCaps = ["device-proof", "read", "resume",
                                     "workspace.close", "workspace.read", "workspace.preview",
                                     "workspace.move", "workspace.group.rename", "workspace.customize"]

    /// `task.stream`: this Mac serves `task:<host>` (agents and tasks).
    /// `task.dispatch`: it also starts tasks. `MobileHost` adds them when a
    /// runner is registered (and, for dispatch, `allowsTaskDispatch` is set).
    public static let taskStreamCap = "task.stream"
    public static let taskDispatchCap = "task.dispatch"

    public init(hostID: String, accountUserID: String, allowsTerminalSpawn: Bool = false, allowsTaskDispatch: Bool = false,
                maxFrame: Int = 256 * 1024, caps: [String] = MobileHostConfiguration.defaultCaps,
                displayName: String = "", appVersion: String = "0", appBuild: String = "0") {
        self.hostID = hostID
        self.accountUserID = accountUserID
        self.allowsTerminalSpawn = allowsTerminalSpawn
        self.allowsTaskDispatch = allowsTaskDispatch
        self.maxFrame = maxFrame
        self.caps = caps
        self.displayName = displayName
        self.appVersion = appVersion
        self.appBuild = appBuild
    }

    /// The authenticated host identity and capability projection consumed by
    /// iOS's Mac compatibility gate. `caps` is the complete owner set; the
    /// hello negotiation still intersects it with the phone's requested caps.
    public var statusPayload: JSONValue {
        .object([
            "mac_device_id": .string(hostID),
            "mac_display_name": .string(displayName),
            "mac_app_version": .string(appVersion),
            "mac_app_build": .string(appBuild),
            "capabilities": .array(caps.map(JSONValue.string)),
        ])
    }
}
