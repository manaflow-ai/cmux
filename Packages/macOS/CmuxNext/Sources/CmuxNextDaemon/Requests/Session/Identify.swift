import Foundation

public struct DaemonIdentity: Sendable, Hashable, Decodable {
    public var app: String
    public var version: String
    public var buildCommit: String?
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
    /// The API revision the daemon speaks (`api_revision`), only in the reply to
    /// `identify {revisions: true}`; nil otherwise and from an older daemon.
    public var apiRevision: UInt32?
    /// The digest of the schema the daemon's method tables came from (`sdk_schema_digest`, 16 hex digits), and
    /// the method ids it answers on REQUEST frames (`framed_methods`): only in the reply to
    /// `identify {revisions: true}` on a connection offered `ipc-frames-v2`; nil otherwise.
    public var sdkSchemaDigest: String?
    public var framedMethods: [UInt16]?

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
        lifecycleReady: Bool = true
    ) {
        self.app = app
        self.version = version
        self.buildCommit = buildCommit
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
    }

    enum CodingKeys: String, CodingKey {
        case app, version, capabilities, session, pid, generation
        case buildCommit = "build_commit"
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
        case apiRevision = "api_revision"
        case sdkSchemaDigest = "sdk_schema_digest"
        case framedMethods = "framed_methods"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(String.self, forKey: .app)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        buildCommit = try c.decodeIfPresent(String.self, forKey: .buildCommit)
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
        apiRevision = try? c.decodeIfPresent(UInt32.self, forKey: .apiRevision)
        sdkSchemaDigest = try? c.decodeIfPresent(String.self, forKey: .sdkSchemaDigest)
        framedMethods = try? c.decodeIfPresent([UInt16].self, forKey: .framedMethods)
    }
}

public struct IdentifyRequest: DaemonRequest {
    public typealias Response = DaemonIdentity
    public static let commandName: DaemonCommandName = "identify"
    /// Explicit owner metadata; omission keeps the original raw response shape.
    public var machineMetadata: Bool?
    /// Adds `api_revision` to the reply. Only a daemon that advertises a framed IPC capability is
    /// asked: an older one refuses the unknown field (`additional_properties: false`).
    public var revisions: Bool?
    public init(machineMetadata: Bool? = nil, revisions: Bool? = nil) {
        self.machineMetadata = machineMetadata
        self.revisions = revisions
    }
    private enum CodingKeys: String, CodingKey { case machineMetadata = "machine_metadata", revisions }
}

public struct SetClientInfoRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let commandName: DaemonCommandName = "set-client-info"
    public var name: String?
    public var kind: String?
    public var capabilities: [String]?
    /// Shared-sizing identity (`shared-sizing-v1`): the device this connection's views are on.
    public var deviceKind: String?
    public var deviceName: String?
    /// The API revision this client speaks (`api_revision`); nil declares none (a revision 12 client).
    public var apiRevision: UInt32?
    public init(name: String? = nil, kind: String? = "frontend", capabilities: [String]? = nil,
                deviceKind: String? = nil, deviceName: String? = nil, apiRevision: UInt32? = nil) {
        self.name = name
        self.kind = kind
        self.capabilities = capabilities
        self.deviceKind = deviceKind
        self.deviceName = deviceName
        self.apiRevision = apiRevision
    }

    enum CodingKeys: String, CodingKey {
        case name, kind, capabilities, deviceKind = "device_kind", deviceName = "device_name", apiRevision = "api_revision"
    }
}
