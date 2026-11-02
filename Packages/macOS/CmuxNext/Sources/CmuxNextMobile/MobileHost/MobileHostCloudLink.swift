public import Foundation

/// One of the account's Cloud machines, passed only over the supervised child's stdin.
/// Rust checks ownership and chooses the exact machine; socket paths never reach a phone.
/// A machine without a live app link (asleep) is listed with no socket: hostd shows it in the
/// phone's directory and its Computer card, and never connects to it.
public struct MobileHostCloudLink: Encodable, Sendable, Equatable {
    public var machineID: String
    public var teamID: String
    public var name: String
    /// The live app link carrier; nil (encoded as `null`) while the machine has no link.
    public var socket: String?
    public var owner: Bool
    /// The machine's ``CloudMachine/Status`` raw value (`running`, `paused`, …).
    public var status: String
    /// The machine has run at least once.
    public var ran: Bool

    public init(machineID: String, teamID: String, name: String, socket: String?, owner: Bool, status: String, ran: Bool) {
        self.machineID = machineID
        self.teamID = teamID
        self.name = name
        self.socket = socket
        self.owner = owner
        self.status = status
        self.ran = ran
    }

    enum CodingKeys: String, CodingKey {
        case machineID = "machine_id", teamID = "team_id", name, socket, owner, status, ran
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machineID, forKey: .machineID)
        try container.encode(teamID, forKey: .teamID)
        try container.encode(name, forKey: .name)
        // Always present: `null` says "asleep", never an older Mac's missing field.
        try container.encode(socket, forKey: .socket)
        try container.encode(owner, forKey: .owner)
        try container.encode(status, forKey: .status)
        try container.encode(ran, forKey: .ran)
    }
}

/// The app's whole answer to `need_cloud_links`: whether the account pays for cmux Cloud, and its machines.
public struct MobileHostCloudLinks: Sendable, Equatable {
    /// The account's plan pays for cmux Cloud; false when the plan is unknown.
    public var paid: Bool
    public var links: [MobileHostCloudLink]

    public init(paid: Bool = false, links: [MobileHostCloudLink] = []) {
        self.paid = paid
        self.links = links
    }
}

extension MobileHostLaunch {
    /// The `cloud_links` answer to hostd's `need_cloud_links`.
    public static func cloudLinksLine(request: UInt64, links: MobileHostCloudLinks) -> Data? {
        cloudLinksLine(request: request, paid: links.paid, links: links.links)
    }

    /// The `cloud_links` answer to hostd's `need_cloud_links`. `paid`: the account pays for cmux Cloud.
    public static func cloudLinksLine(request: UInt64, paid: Bool, links: [MobileHostCloudLink]) -> Data? {
        struct Reply: Encodable {
            let type = "cloud_links"
            let request: UInt64
            let paid: Bool
            let links: [MobileHostCloudLink]
        }
        guard var data = try? JSONEncoder().encode(Reply(request: request, paid: paid, links: links)) else { return nil }
        data.append(0x0a)
        return data
    }
}
