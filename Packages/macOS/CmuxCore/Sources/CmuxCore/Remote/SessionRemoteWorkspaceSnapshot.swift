/// The durable, codable subset of a remote-workspace configuration persisted
/// in session snapshots so a remote workspace can be restored across launches.
///
/// Wire/persistence shape: field names are encoded by `Codable`; do not rename
/// stored properties without a migration.
public struct SessionRemoteWorkspaceSnapshot: Codable, Equatable, Sendable {
    /// The transport the workspace used when the snapshot was taken.
    public var transport: WorkspaceRemoteTransport
    /// SSH destination (`user@host` or `host`).
    public var destination: String
    /// Explicit SSH port, when one was configured.
    public var port: Int?
    /// Explicit identity file path, when one was configured.
    public var identityFile: String?
    /// Durable `-o` SSH options captured from the live configuration.
    public var sshOptions: [String]
    /// Whether remote PTY sessions outlive their local terminal surface.
    public var preserveAfterTerminalExit: Bool?
    /// Whether daemon bootstrap is skipped (pre-baked Cloud VM images).
    public var skipDaemonBootstrap: Bool?
    /// The CLI relay port captured for persistent-PTY restore.
    public var relayPort: Int? = nil
    /// The persistent daemon slot captured for persistent-PTY restore.
    public var persistentDaemonSlot: String? = nil
    /// Provider-issued Cloud VM id for cmux-managed Cloud VM workspaces.
    public var managedCloudVMID: String? = nil

    /// Creates a snapshot value; mirrors the synthesized memberwise initializer.
    public init(
        transport: WorkspaceRemoteTransport,
        destination: String,
        port: Int? = nil,
        identityFile: String? = nil,
        sshOptions: [String] = [],
        preserveAfterTerminalExit: Bool? = nil,
        skipDaemonBootstrap: Bool? = nil,
        relayPort: Int? = nil,
        persistentDaemonSlot: String? = nil,
        managedCloudVMID: String? = nil
    ) {
        self.transport = transport
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.preserveAfterTerminalExit = preserveAfterTerminalExit
        self.skipDaemonBootstrap = skipDaemonBootstrap
        self.relayPort = relayPort
        self.persistentDaemonSlot = persistentDaemonSlot
        self.managedCloudVMID = managedCloudVMID
    }
}
