struct RemoteHookSnapshotEntry: Codable {
    let path: String
    let kind: String
    let contentBase64: String?
    let mode: UInt16

    enum CodingKeys: String, CodingKey {
        case path, kind, mode
        case contentBase64 = "content_base64"
    }
}
