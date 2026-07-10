struct DeviceListResponse: Decodable {
    let devices: [String: [DeviceRecord]]
}
