/// Writes `WireSchemaIdentity.built`, the values CmuxNextIPC's `WireSchemaIdentity` declares
/// (the same values cmux-ipc's build.rs writes as `SCHEMA_IDENTITY`).
struct IdentityEmitter {
    let sdk: SchemaFile<SDKSchemaHeader>
    let resource: SchemaFile<ResourceOperationsHeader>

    func emit() -> String {
        let fields = [
            "muxProtocol: \(Self.literal(sdk.header.`protocol`.name))",
            "muxProtocolVersion: \(sdk.header.`protocol`.version)",
            "resourceProtocol: \(Self.literal(resource.header.`protocol`))",
            "commandCount: \(sdk.header.commands.count)",
            "eventCount: \(sdk.header.events.count)",
            "resourceOperationCount: \(resource.header.operations.count)",
            "localOperationCount: \(resource.header.localOperations.count)",
            "sdkSchemaDigest: \(Self.hex(sdk.digest))",
            "resourceOperationsDigest: \(Self.hex(resource.digest))",
        ]
        let arguments = fields.joined(separator: ",\n        ")
        return """
        // Built by CmuxNextWireGen from cmux-tui/spec at build time; not in git (p05-ipc task 027).

        extension WireSchemaIdentity {
            /// The schema this build compiled.
            public static let built = WireSchemaIdentity(
                \(arguments)
            )
        }

        """
    }

    /// A Swift string literal for `value`.
    static func literal(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x20...0x7E: out.unicodeScalars.append(scalar)
            default: out += "\\u{\(String(scalar.value, radix: 16))}"
            }
        }
        return out + "\""
    }

    /// `0x` and sixteen hex digits.
    static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return "0x" + String(repeating: "0", count: 16 - digits.count) + digits
    }
}
