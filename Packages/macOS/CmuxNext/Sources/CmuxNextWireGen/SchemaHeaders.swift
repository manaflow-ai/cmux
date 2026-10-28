/// Any JSON value, decoded and dropped: the identity counts keys, not their values.
struct OpaqueJSON: Decodable {
    init(from decoder: any Decoder) throws {}
}

/// The parts of cmux-tui/spec/sdk-schema.json the identity reads.
struct SDKSchemaHeader: Decodable {
    struct ProtocolInfo: Decodable {
        let name: String
        let version: UInt64
    }

    let `protocol`: ProtocolInfo
    let commands: [String: OpaqueJSON]
    let events: [String: OpaqueJSON]
}

/// The parts of cmux-tui/spec/resource-operations-v2.json the identity reads.
struct ResourceOperationsHeader: Decodable {
    let `protocol`: String
    let operations: [String: OpaqueJSON]
    let localOperations: [String: OpaqueJSON]

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case operations
        case localOperations = "local_operations"
    }
}
