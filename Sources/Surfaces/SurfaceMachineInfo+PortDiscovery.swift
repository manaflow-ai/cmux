import Foundation

extension SurfaceMachineInfo {
    init(
        id: SurfaceMachineID,
        name: String,
        status: String,
        image: String?,
        hasDesktop: Bool,
        memoryMb: Int?,
        diskMb: Int?,
        linkState: SurfaceLinkState,
        linkError: String?,
        cpuPercent: Double?,
        memoryUsedMb: Int?,
        diskUsedMb: Int?,
        remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil,
        privateAddress: String? = nil,
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
        self.portDiscoveryState = portDiscoveryState
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, status, image, hasDesktop, memoryMb, diskMb, linkState, linkError
        case cpuPercent, memoryUsedMb, diskUsedMb, remoteWorkspaces, privateAddress
        case portDiscoveryState
    }

    init(from decoder: Decoder) throws {
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
        portDiscoveryState = try values.decodeIfPresent(CloudPortDiscoveryState.self, forKey: .portDiscoveryState) ?? .notRequested
    }
}
