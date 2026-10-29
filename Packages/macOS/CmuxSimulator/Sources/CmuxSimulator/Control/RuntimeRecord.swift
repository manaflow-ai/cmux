struct RuntimeRecord: Decodable {
    let identifier: String
    let name: String
    let version: String?
    let isAvailable: Bool?
    let supportedDeviceTypes: [RuntimeDeviceType]?
}
