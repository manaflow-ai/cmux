import Foundation

extension SurfaceMachineInfo {
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
