import Foundation

public struct DaemonIdentity: Sendable, Hashable, Decodable {
    public var app: String
    public var version: String
    public var buildCommit: String?
    /// The exact build of the binary that serves the socket (`build_id`, `daemon-build-v1`): the
    /// stamped commit, or for an unstamped build the commit plus `-dirty.<hash>`; nil on older daemons.
    public var buildID: String?
    public var ghosttyCommit: String?
    public var protocolVersion: Int
    public var capabilities: [String] { didSet { capabilitySet = Self.lookup(capabilities) } }
    /// `capabilities` for ``supports(_:)``, as native strings: the app asks per
    /// tab per snapshot, and a linear scan of decoded (bridged) strings held
    /// the main thread in CoreFoundation and allocator locks (cx-6so.21).
    private var capabilitySet: Set<String>
    public var session: String
    public var pid: Int32
    public var registryID: String?
    /// The opaque owner ID returned by `machine.list`; nil on older daemons.
    /// UI routes, host names and session registry IDs cannot substitute for it.
    public var machineResourceID: ResourceID?
    /// Canonical session ID returned by enriched owner metadata, distinct from registryID.
    public var sessionResourceID: ResourceID?
    /// Platform observed from this owner, distinct from the client's platform.
    public var machinePlatform: MachineCatalogPlatform?
    /// Machine-level capabilities, distinct from the protocol feature names above.
    public var machineCapabilities: [String]
    /// The host name the daemon runs on (`session-identity-v1`); nil on older daemons.
    public var machineName: String?
    public var generation: DaemonGeneration
    public var workspaceRevision: UInt64
    public var lifecycleReady: Bool
    /// The daemon's launch snapshot file (`launch-snapshot-v1`), read by the
    /// next launch before it connects (`LaunchSnapshot`).
    public var launchSnapshotPath: String?
    /// The absolute path of the binary that serves the socket (`daemon-build-v1`, cmux-tui
    /// `server/daemon_build.rs`); nil on older daemons.
    public var cliPath: String?

    public func supports(_ capability: String) -> Bool { capabilitySet.contains(capability) }

    private static func lookup(_ capabilities: [String]) -> Set<String> {
        Set(capabilities.map { var native = $0; native.makeContiguousUTF8(); return native })
    }

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
        buildID: String? = nil,
        ghosttyCommit: String? = nil,
        protocolVersion: Int = 12,
        capabilities: [String] = [],
        session: String = "test",
        pid: Int32 = 0,
        registryID: String? = nil,
        machineResourceID: ResourceID? = nil,
        sessionResourceID: ResourceID? = nil,
        machinePlatform: MachineCatalogPlatform? = nil,
        machineCapabilities: [String] = [],
        machineName: String? = nil,
        generation: DaemonGeneration,
        workspaceRevision: UInt64 = 0,
        lifecycleReady: Bool = true,
        cliPath: String? = nil
    ) {
        self.app = app
        self.version = version
        self.buildCommit = buildCommit
        self.buildID = buildID
        self.ghosttyCommit = ghosttyCommit
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        capabilitySet = Self.lookup(capabilities)
        self.session = session
        self.pid = pid
        self.registryID = registryID
        self.machineResourceID = machineResourceID
        self.sessionResourceID = sessionResourceID
        self.machinePlatform = machinePlatform
        self.machineCapabilities = machineCapabilities
        self.machineName = machineName
        self.generation = generation
        self.workspaceRevision = workspaceRevision
        self.lifecycleReady = lifecycleReady
        self.cliPath = cliPath
    }

    enum CodingKeys: String, CodingKey {
        case app, version, capabilities, session, pid, generation
        case buildCommit = "build_commit"
        case buildID = "build_id"
        case ghosttyCommit = "ghostty_commit"
        case protocolVersion = "protocol"
        case registryID = "registry_id"
        case machineResourceID = "machine_id"
        case sessionResourceID = "session_resource_id"
        case machinePlatform = "machine_platform"
        case machineCapabilities = "machine_capabilities"
        case machineName = "machine_name"
        case workspaceRevision = "workspace_revision"
        case lifecycleReady = "lifecycle_ready"
        case launchSnapshotPath = "launch_snapshot_path"
        case cliPath = "cli_path"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(String.self, forKey: .app)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        buildCommit = try c.decodeIfPresent(String.self, forKey: .buildCommit)
        buildID = try c.decodeIfPresent(String.self, forKey: .buildID)
        ghosttyCommit = try c.decodeIfPresent(String.self, forKey: .ghosttyCommit)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        capabilitySet = Self.lookup(capabilities)
        session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        registryID = try c.decodeIfPresent(String.self, forKey: .registryID)
        machineResourceID = try c.decodeIfPresent(String.self, forKey: .machineResourceID)
            .flatMap { $0.isEmpty ? nil : ResourceID(rawValue: $0) }
        sessionResourceID = try c.decodeIfPresent(String.self, forKey: .sessionResourceID)
            .flatMap { $0.isEmpty ? nil : ResourceID(rawValue: $0) }
        machinePlatform = try c.decodeIfPresent(MachineCatalogPlatform.self, forKey: .machinePlatform)
        machineCapabilities = try c.decodeIfPresent([String].self, forKey: .machineCapabilities) ?? []
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName).flatMap { $0.isEmpty ? nil : $0 }
        generation = try c.decode(DaemonGeneration.self, forKey: .generation)
        workspaceRevision = try c.decodeIfPresent(UInt64.self, forKey: .workspaceRevision) ?? 0
        lifecycleReady = try c.decodeIfPresent(Bool.self, forKey: .lifecycleReady) ?? true
        launchSnapshotPath = try? c.decodeIfPresent(String.self, forKey: .launchSnapshotPath)
        cliPath = (try? c.decodeIfPresent(String.self, forKey: .cliPath)).flatMap { $0 }.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }
}

public struct IdentifyRequest: DaemonRequest {
    public typealias Response = DaemonIdentity
    public static let command = "identify"
    /// Explicit owner metadata; omission keeps the original raw response shape.
    public var machineMetadata: Bool?
    public init(machineMetadata: Bool? = nil) { self.machineMetadata = machineMetadata }
    private enum CodingKeys: String, CodingKey { case machineMetadata = "machine_metadata" }
}

public struct SetClientInfoRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-client-info"
    public var name: String?
    public var kind: String?
    public var capabilities: [String]?
    /// Shared-sizing identity (`shared-sizing-v1`): the device this connection's views are on.
    public var deviceKind: String?
    public var deviceName: String?
    public init(name: String? = nil, kind: String? = "frontend", capabilities: [String]? = nil,
                deviceKind: String? = nil, deviceName: String? = nil) {
        self.name = name
        self.kind = kind
        self.capabilities = capabilities
        self.deviceKind = deviceKind
        self.deviceName = deviceName
    }
}
