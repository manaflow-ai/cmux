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

    /// Only a state: a Worker machine (the app server link) has no stats route.
    public init(state: String) { self.state = state }
}

/// One snapshot, as cmux-cloud-machine `models::read("snapshot")` answers it (its id under `snapshotId` or `id`).
public struct CloudSnapshot: Sendable, Hashable, Codable {
    public var id: String
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }
}
