struct SimulatorDeviceChromePadding: Decodable {
    let top: Double
    let left: Double
    let bottom: Double
    let right: Double

    static let zero = SimulatorDeviceChromePadding(top: 0, left: 0, bottom: 0, right: 0)
}
