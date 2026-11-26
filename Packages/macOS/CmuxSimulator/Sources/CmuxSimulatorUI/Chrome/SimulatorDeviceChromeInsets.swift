struct SimulatorDeviceChromeInsets: Equatable, Sendable {
    let top: Double
    let leading: Double
    let bottom: Double
    let trailing: Double

    static let zero = SimulatorDeviceChromeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
}
