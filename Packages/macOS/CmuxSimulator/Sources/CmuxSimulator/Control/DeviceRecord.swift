struct DeviceRecord: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool?
    let deviceTypeIdentifier: String
    let lastBootedAt: String?
}
