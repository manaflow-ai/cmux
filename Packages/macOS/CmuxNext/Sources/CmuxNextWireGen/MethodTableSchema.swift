import Foundation

// Reads the framed-IPC method attributes out of cmux-tui/spec/sdk-schema.json
// and cmux-tui/spec/resource-operations-v2.json for TableEmitter. The Rust
// twin is cmux-tui/crates/cmux-ipc/build-support/method_tables.rs; both refuse
// the same schemas and both are checked against
// cmux-tui/spec/fixtures/ipc-method-tables.
//
// A method without an id is not framed and stays out of the tables. The codegen
// validator (cmux-tui/bindings/codegen/ipc_meta.py) owns the full rule set;
// this reader refuses only what the tables cannot encode, so a table never
// disagrees with its schema.

/// Why a schema cannot become a table. `path` is a JSON path into `file`.
struct MethodTableSchemaError: Error, Equatable, CustomStringConvertible {
    let file: String
    let path: String
    let message: String

    var description: String { "\(file): \(path): \(message)" }
}

/// A JSON value as the schema files hold it. Booleans and integers stay
/// apart, so `"urgent": 1` is refused instead of read as true.
enum SchemaJSON: Decodable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([SchemaJSON])
    case object([String: SchemaJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SchemaJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SchemaJSON].self))
        }
    }

    subscript(key: String) -> SchemaJSON? {
        if case .object(let members) = self { members[key] } else { nil }
    }

    var object: [String: SchemaJSON]? {
        if case .object(let members) = self { members } else { nil }
    }

    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var integer: Int64? {
        if case .integer(let value) = self { value } else { nil }
    }

    var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }
}

/// The framed methods and events of the two schema files, grouped into dense
/// families. Variant fields hold the Swift case name TableEmitter writes.
struct MethodTableSchema: Equatable {
    /// Which id space a family lives in, with its family range.
    enum Space: Equatable {
        case v12
        case v2
        case events

        var range: ClosedRange<UInt8> {
            switch self {
            case .v12: 0x01...0x5F
            case .v2: 0x60...0xBF
            case .events: 0xC0...0xFE
            }
        }
    }

    struct Coalesce: Equatable {
        let key: [String]
        let additive: [String]
    }

    struct Method: Equatable {
        let id: UInt16
        let name: String
        let priority: String
        let ordering: String
        let durability: String
        /// nil is JSON; a value is a binary layout of that version.
        let binaryLayout: UInt8?
        let streamScoped: Bool
        let crossesStreamOK: String?
        let maxBytes: UInt32?
        let coalesce: Coalesce?
        let urgent: Bool
        /// The schema's `clients`; nil (absent) is every client.
        let clients: [String]?

        /// Whether `client` calls this method.
        func serves(_ client: String) -> Bool {
            clients?.contains(client) ?? true
        }
    }

    struct Event: Equatable {
        let id: UInt16
        let name: String
        let priority: String
        let coalesce: Coalesce?
    }

    struct Family<Row: Equatable>: Equatable {
        let id: UInt8
        let name: String
        /// Indexed by ordinal; nil is an ordinal no method holds.
        let slots: [Row?]
    }

    /// The frame header's length cap (design 3.2); `max_bytes` cannot exceed it.
    static let maxFrameBytes: Int64 = 32 * 1024 * 1024
    static let sdkFile = "sdk-schema.json"
    static let v2File = "resource-operations-v2.json"

    /// The `clients` value of the macOS app, the only client CmuxNextIPC serves.
    static let macOSClient = "macos"

    let v12: [Family<Method>]
    let v2: [Family<Method>]
    let events: [Family<Event>]

    /// Reads both schema files, keeping the commands and operations `client`
    /// calls (events have no `clients` and are all kept).
    init(sdkSchema: Data, resourceOperations: Data, client: String = macOSClient) throws(MethodTableSchemaError) {
        let sdk = try Self.decode(sdkSchema, file: Self.sdkFile)
        let v2 = try Self.decode(resourceOperations, file: Self.v2File)
        try self.init(sdk: sdk, v2: v2, client: client)
    }

    init(sdk: SchemaJSON, v2: SchemaJSON, client: String = macOSClient) throws(MethodTableSchemaError) {
        var sdkReader = MethodTableSchemaReader(file: Self.sdkFile, document: sdk)
        var v2Reader = MethodTableSchemaReader(file: Self.v2File, document: v2)
        try sdkReader.declareFamilies(spaces: [.v12, .events])
        try v2Reader.declareFamilies(spaces: [.v2])
        self.v12 = try sdkReader.methods(key: "commands", space: .v12, client: client)
        self.v2 = try v2Reader.methods(key: "operations", space: .v2, client: client)
        self.events = try sdkReader.events()
    }

    private static func decode(_ data: Data, file: String) throws(MethodTableSchemaError) -> SchemaJSON {
        do {
            return try JSONDecoder().decode(SchemaJSON.self, from: data)
        } catch {
            throw MethodTableSchemaError(file: file, path: "$", message: "not JSON: \(error)")
        }
    }
}
