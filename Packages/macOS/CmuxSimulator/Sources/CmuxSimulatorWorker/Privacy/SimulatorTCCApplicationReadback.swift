struct SimulatorTCCApplicationReadback: Equatable, Sendable {
    let applications: [SimulatorTCCApplicationRows]
    let isTruncated: Bool
}
