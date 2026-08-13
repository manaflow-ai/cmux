struct SimulatorDeviceChromeInput: Decodable {
    let name: String
    let image: String?
    let imageDown: String?
    let onTop: Bool?
    let usagePage: UInt32?
    let usage: UInt32?
    let anchor: String
    let align: String?
    let offsets: SimulatorDeviceChromeOffsets
}
