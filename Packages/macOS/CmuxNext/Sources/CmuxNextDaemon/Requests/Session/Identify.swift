import Foundation

public struct DaemonIdentity: Sendable, Hashable, Decodable {
    public var app: String
    public var version: String
    public var buildCommit: String?
    public var ghosttyCommit: String?
    public var protocolVersion: Int
    public var capabilities: [String]
    public var session: String
    public var pid: Int32
    public var registryID: String?
    /// The host name the daemon runs on (`session-identity-v1`); nil on older daemons.
    public var machineName: String?
    public var generation: DaemonGeneration
    public var workspaceRevision: UInt64
    public var lifecycleReady: Bool
    /// The daemon's launch snapshot file (`launch-snapshot-v1`), read by the
    /// next launch before it connects (`LaunchSnapshot`).
    public var launchSnapshotPath: String?

    public func supports(_ capability: String) -> Bool { capabilities.contains(capability) }

    /// The session's stable identity: `registry_id`, the UUID its SQLite
    /// registry records once. It survives daemon restarts, in-place upgrades
    /// and host adoption, and every deployed build reports it (a Cloud VM on
    /// the image's cmux-tui included). `session` is the session's name and
    /// `generation` fences one daemon boot; neither is an identity.
    public var sessionID: String? { registryID.flatMap { $0.isEmpty ? nil : $0.lowercased() } }

    public init(
        app: String = "cmux-tui",
        version: String = "0",
        buildCommit: String? = nil,
        ghosttyCommit: String? = nil,
        protocolVersion: Int = 12,
        capabilities: [String] = [],
        session: String = "test",
        pid: Int32 = 0,
        registryID: String? = nil,
        machineName: String? = nil,
        generation: DaemonGeneration,
        workspaceRevision: UInt64 = 0,
        lifecycleReady: Bool = true
    ) {
        self.app = app
        self.version = version
        self.buildCommit = buildCommit
        self.ghosttyCommit = ghosttyCommit
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.session = session
        self.pid = pid
        self.registryID = registryID
        self.machineName = machineName
        self.generation = generation
        self.workspaceRevision = workspaceRevision
        self.lifecycleReady = lifecycleReady
    }

    enum CodingKeys: String, CodingKey {
        case app, version, capabilities, session, pid, generation
        case buildCommit = "build_commit"
        case ghosttyCommit = "ghostty_commit"
        case protocolVersion = "protocol"
        case registryID = "registry_id"
        case machineName = "machine_name"
        case workspaceRevision = "workspace_revision"
        case lifecycleReady = "lifecycle_ready"
        case launchSnapshotPath = "launch_snapshot_path"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(String.self, forKey: .app)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        buildCommit = try c.decodeIfPresent(String.self, forKey: .buildCommit)
        ghosttyCommit = try c.decodeIfPresent(String.self, forKey: .ghosttyCommit)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        registryID = try c.decodeIfPresent(String.self, forKey: .registryID)
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName).flatMap { $0.isEmpty ? nil : $0 }
        generation = try c.decode(DaemonGeneration.self, forKey: .generation)
        workspaceRevision = try c.decodeIfPresent(UInt64.self, forKey: .workspaceRevision) ?? 0
        lifecycleReady = try c.decodeIfPresent(Bool.self, forKey: .lifecycleReady) ?? true
        launchSnapshotPath = try? c.decodeIfPresent(String.self, forKey: .launchSnapshotPath)
    }
}

public struct IdentifyRequest: DaemonRequest {
    public typealias Response = DaemonIdentity
    public static let command = "identify"
    public init() {}
}

public struct SetClientInfoRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-client-info"
    public var name: String?
    public var kind: String?
    public var capabilities: [String]?
    public init(name: String? = nil, kind: String? = "frontend", capabilities: [String]? = nil) {
        self.name = name
        self.kind = kind
        self.capabilities = capabilities
    }
}
