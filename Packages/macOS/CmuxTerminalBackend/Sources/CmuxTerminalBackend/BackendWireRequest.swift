struct BackendWireRequest: Encodable {
    let id: UInt64
    let command: String
    let parameters: [String: BackendJSONValue]

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: BackendCodingKey.self)
        try container.encode(id, forKey: BackendCodingKey("id"))
        try container.encode(command, forKey: BackendCodingKey("cmd"))
        for (key, value) in parameters {
            guard key != "id", key != "cmd" else {
                throw BackendProtocolError.malformedMessage
            }
            try container.encode(value, forKey: BackendCodingKey(key))
        }
    }
}
