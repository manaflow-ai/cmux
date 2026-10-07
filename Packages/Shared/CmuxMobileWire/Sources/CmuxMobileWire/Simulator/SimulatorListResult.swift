/// `simulator.list` result.
public struct SimulatorListResult: Hashable, Sendable, Codable {
    public var simulators: [SimulatorInfo]

    public init(simulators: [SimulatorInfo]) {
        self.simulators = simulators
    }
}
