struct RemoteHookMutation: Encodable {
    let path: String
    let delete: Bool
    let contentBase64: String?
    let mode: UInt16?

    enum CodingKeys: String, CodingKey {
        case path, delete, mode
        case contentBase64 = "content_base64"
    }
}
