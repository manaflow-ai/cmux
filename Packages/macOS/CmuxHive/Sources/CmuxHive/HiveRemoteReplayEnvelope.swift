import CmuxMobileRPC
import Foundation

/// Requires host routing identity without changing the mobile replay decoder's compatibility contract.
nonisolated struct HiveRemoteReplayEnvelope: Decodable, Sendable {
    let workspaceID: String
    let surfaceID: String
    let response: MobileTerminalReplayResponse

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        surfaceID = try container.decode(String.self, forKey: .surfaceID)
        response = try MobileTerminalReplayResponse(from: decoder)
    }
}
