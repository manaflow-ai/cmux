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
