import Foundation

/// `GET /api/vm/{id}/stats`; reading never wakes a sleeping machine.
public struct CloudMachineStats: Sendable, Hashable, Decodable {
    public var state: String
    public var cpus: Int?
    public var cpuPercent: Double?
    public var memoryTotalMb: Double?
    public var memoryUsedMb: Double?
    public var diskTotalMb: Double?
    public var diskUsedMb: Double?
}

/// One snapshot from `GET /api/vm/{id}/snapshots` or `POST …/snapshot`.
public struct CloudSnapshot: Sendable, Hashable, Decodable {
    public var id: String
    public var name: String?

    enum CodingKeys: String, CodingKey { case id, snapshotId, name }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .snapshotId) ?? c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}

/// `POST /api/vm/{id}/open-port`.
public struct CloudPortLink: Sendable, Hashable, Decodable {
    public var url: String
    public var openUrl: String?
}
