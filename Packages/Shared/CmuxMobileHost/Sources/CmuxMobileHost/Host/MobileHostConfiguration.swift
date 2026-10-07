/// Static inputs of one Mac host.
public struct MobileHostConfiguration: Sendable {
    /// This Mac's host id (`h_…`, the id `HostDO` and the proof name).
    public var hostID: String
    /// The account user the Mac is signed into; only its devices are admitted.
    public var accountUserID: String
    /// Off until a live verification shows phone-created terminals run here as
    /// the login shell with no phone input in argv, cwd or env.
    public var allowsTerminalSpawn: Bool
    /// `hello.ok.max_frame`.
    public var maxFrame: Int
    /// Caps this host offers in `hello.ok` (intersected with the client's).
    public var caps: [String]

    /// `workspace.close`, `workspace.read` and `workspace.preview` tell the
    /// phone it may offer Close and Mark as Read and that rows carry preview
    /// lines (c5-workspaces.md section 2); they also go up in `host.caps.set`.
    public static let defaultCaps = ["device-proof", "read", "resume",
                                     "workspace.close", "workspace.read", "workspace.preview"]

    public init(hostID: String, accountUserID: String, allowsTerminalSpawn: Bool = false, maxFrame: Int = 256 * 1024,
                caps: [String] = MobileHostConfiguration.defaultCaps) {
        self.hostID = hostID
        self.accountUserID = accountUserID
        self.allowsTerminalSpawn = allowsTerminalSpawn
        self.maxFrame = maxFrame
        self.caps = caps
    }
}
