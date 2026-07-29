struct SimulatorFramePublicationWord: Equatable, Sendable {
    let rawValue: Int64

    var reportsSourceFailure: Bool {
        rawValue == Int64.min
    }
}
