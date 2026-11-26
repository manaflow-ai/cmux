struct SimulatorDeviceChromePoint: Decodable {
    let x: Double
    let y: Double

    static let zero = SimulatorDeviceChromePoint(x: 0, y: 0)
}
