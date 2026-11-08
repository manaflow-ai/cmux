struct SimulatorDeviceChrome: Decodable {
    let images: SimulatorDeviceChromeImages
    let paths: SimulatorDeviceChromePaths
    let inputs: [SimulatorDeviceChromeInput]
}
