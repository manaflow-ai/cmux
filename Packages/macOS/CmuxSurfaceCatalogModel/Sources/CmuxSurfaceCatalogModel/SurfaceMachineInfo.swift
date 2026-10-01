import Foundation

/// What a provider knows about its machine, for the tree header.
public struct SurfaceMachineInfo: Hashable, Codable, Sendable {
    public var id: SurfaceMachineID
    public var name: String
    /// `running`, `standby`, … for cloud machines; `running` for the local Mac.
    public var status: String
    public var image: String?
    public var hasDesktop: Bool
    public var memoryMb: Int?
    public var diskMb: Int?
    public var linkState: SurfaceLinkState
    public var linkError: String?
    public var cpuPercent: Double?
    public var memoryUsedMb: Int?
    public var diskUsedMb: Int?
    /// Every cmux-tui workspace on the machine, in the daemon's order — including empty
    /// ones, which have no terminal to be derived from. nil when unknown (asleep, local).
    public var remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil
    /// The machine's address on its owner's private network (v4 preferred), reachable through WireGuard; nil for local or legacy machines.
    public var privateAddress: String? = nil
    /// Account presence for another Mac's app instance; nil for local and cloud machines.
    public var presence: SurfaceDevicePresence? = nil
    public var portDiscoveryState: CloudPortDiscoveryState = .notRequested

    public init(
        id: SurfaceMachineID,
        name: String,
        status: String,
        image: String? = nil,
        hasDesktop: Bool,
        memoryMb: Int? = nil,
        diskMb: Int? = nil,
        linkState: SurfaceLinkState,
        linkError: String? = nil,
        cpuPercent: Double? = nil,
        memoryUsedMb: Int? = nil,
        diskUsedMb: Int? = nil,
        remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil,
        privateAddress: String? = nil,
        presence: SurfaceDevicePresence? = nil,
        portDiscoveryState: CloudPortDiscoveryState = .notRequested
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.image = image
        self.hasDesktop = hasDesktop
        self.memoryMb = memoryMb
        self.diskMb = diskMb
        self.linkState = linkState
        self.linkError = linkError
        self.cpuPercent = cpuPercent
        self.memoryUsedMb = memoryUsedMb
        self.diskUsedMb = diskUsedMb
        self.remoteWorkspaces = remoteWorkspaces
        self.privateAddress = privateAddress
        self.presence = presence
        self.portDiscoveryState = portDiscoveryState
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, status, image, hasDesktop, memoryMb, diskMb, linkState, linkError
        case cpuPercent, memoryUsedMb, diskUsedMb, remoteWorkspaces, privateAddress, presence
        case portDiscoveryState
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(SurfaceMachineID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        status = try values.decode(String.self, forKey: .status)
        image = try values.decodeIfPresent(String.self, forKey: .image)
        hasDesktop = try values.decode(Bool.self, forKey: .hasDesktop)
        memoryMb = try values.decodeIfPresent(Int.self, forKey: .memoryMb)
        diskMb = try values.decodeIfPresent(Int.self, forKey: .diskMb)
        linkState = try values.decode(SurfaceLinkState.self, forKey: .linkState)
        linkError = try values.decodeIfPresent(String.self, forKey: .linkError)
        cpuPercent = try values.decodeIfPresent(Double.self, forKey: .cpuPercent)
        memoryUsedMb = try values.decodeIfPresent(Int.self, forKey: .memoryUsedMb)
        diskUsedMb = try values.decodeIfPresent(Int.self, forKey: .diskUsedMb)
        remoteWorkspaces = try values.decodeIfPresent([SurfaceRemoteWorkspace].self, forKey: .remoteWorkspaces)
        privateAddress = try values.decodeIfPresent(String.self, forKey: .privateAddress)
        presence = try values.decodeIfPresent(SurfaceDevicePresence.self, forKey: .presence)
        portDiscoveryState = try values.decodeIfPresent(CloudPortDiscoveryState.self, forKey: .portDiscoveryState) ?? .notRequested
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(status, forKey: .status)
        try values.encodeIfPresent(image, forKey: .image)
        try values.encode(hasDesktop, forKey: .hasDesktop)
        try values.encodeIfPresent(memoryMb, forKey: .memoryMb)
        try values.encodeIfPresent(diskMb, forKey: .diskMb)
        try values.encode(linkState, forKey: .linkState)
        try values.encodeIfPresent(linkError, forKey: .linkError)
        try values.encodeIfPresent(cpuPercent, forKey: .cpuPercent)
        try values.encodeIfPresent(memoryUsedMb, forKey: .memoryUsedMb)
        try values.encodeIfPresent(diskUsedMb, forKey: .diskUsedMb)
        try values.encodeIfPresent(remoteWorkspaces, forKey: .remoteWorkspaces)
        try values.encodeIfPresent(privateAddress, forKey: .privateAddress)
        try values.encodeIfPresent(presence, forKey: .presence)
        try values.encode(portDiscoveryState, forKey: .portDiscoveryState)
    }
}

