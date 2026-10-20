struct SimulatorDeviceChromeImages: Decodable {
    let topLeft: String?
    let top: String?
    let topRight: String?
    let right: String?
    let bottomRight: String?
    let bottom: String?
    let bottomLeft: String?
    let left: String?
    let composite: String?
    let sizing: SimulatorDeviceChromeSizing
    let devicePadding: SimulatorDeviceChromePadding?

    var assetNames: [String: String] {
        [
            "topLeft": topLeft,
            "top": top,
            "topRight": topRight,
            "right": right,
            "bottomRight": bottomRight,
            "bottom": bottom,
            "bottomLeft": bottomLeft,
            "left": left,
        ].compactMapValues { $0 }
    }
}
