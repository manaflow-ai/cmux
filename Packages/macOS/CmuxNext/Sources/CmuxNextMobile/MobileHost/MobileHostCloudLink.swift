public import Foundation

/// A current app-server Cloud carrier, passed only over the supervised child's stdin.
/// Rust checks ownership and chooses the exact machine; socket paths never reach a phone.
public struct MobileHostCloudLink: Encodable, Sendable, Equatable {
    public var machineID: String
    public var teamID: String
    public var name: String
    public var socket: String
    public var owner: Bool

    public init(machineID: String, teamID: String, name: String, socket: String, owner: Bool) {
        self.machineID = machineID
        self.teamID = teamID
        self.name = name
        self.socket = socket
        self.owner = owner
    }

    enum CodingKeys: String, CodingKey {
        case machineID = "machine_id", teamID = "team_id", name, socket, owner
    }
}

extension MobileHostLaunch {
    public static func cloudLinksLine(request: UInt64, links: [MobileHostCloudLink]) -> Data? {
        struct Reply: Encodable {
            let type = "cloud_links"
            let request: UInt64
            let links: [MobileHostCloudLink]
        }
        guard var data = try? JSONEncoder().encode(Reply(request: request, links: links)) else { return nil }
        data.append(0x0a)
        return data
    }
}
