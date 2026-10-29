import Foundation

// Reads the commands of cmux-tui/spec/sdk-schema.json that the macOS app calls
// into the shapes RequestEmitter writes (p05-ipc.md section 3.3, task 021).
// Named schema types stay names here: TypeEmitter (task 020) emits them, as
// Mojo's generator emits a struct once and every interface that uses it refers
// to it (mojo/public/tools/bindings/generators/mojom_cpp_generator.py).

/// Why a command cannot become a request type. `path` is a JSON path into sdk-schema.json.
struct RequestSchemaError: Error, Equatable, CustomStringConvertible {
    let path: String
    let message: String

    var description: String { "\(MethodTableSchema.sdkFile): \(path): \(message)" }
}

struct RequestCommand: Equatable {
    let wire: String
    /// The struct name, `<Name>Request`.
    let typeName: String
    let methodID: UInt16?
    /// The family's schema name, or `unframed` for a command without a method id.
    let family: String
    let spawnsTerminal: Bool
    let fields: [WireType.Field]
    /// `.object` (named `Response`) for an inline result, else the result type.
    let response: WireType
}

/// The request types of one client's commands, by wire name.
struct RequestSchema: Equatable {
    /// Request names that differ from the command's: the struct keeps the name callers already use.
    static let typeNames = ["send": "SendInput"]
    /// The handle type of an `Id` field, by wire field name (the handles of Wire/Handles.swift);
    /// any other `Id` stays a raw `UInt64`.
    static let idTypes = [
        "surface": "SurfaceID", "surfaces": "SurfaceID", "pane": "PaneID", "panes": "PaneID",
        "screen": "ScreenID", "screens": "ScreenID", "workspace": "WorkspaceHandle", "split": "SplitID",
        "column": "ColumnID", "after_column": "ColumnID", "row": "RowID", "client": "ClientID",
        "notification": "NotificationID",
    ]
    /// Aliases with a Swift type of their own; the others resolve to their target.
    static let aliasTypes = ["Base64": "Data"]
    /// The `opaque_json` type of an arbitrary JSON document; the others hold a number or a string.
    static let documentType = "JsonValue"
    /// Keys `RequestEnvelope` writes around every request's fields.
    static let envelopeKeys: Set = ["id", "cmd"]
    static let scalars = [
        "string": "String", "boolean": "Bool", "int32": "Int32", "uint16": "UInt16", "uint32": "UInt32",
        "int64": "Int64", "uint64": "UInt64", "float32": "Float", "float64": "Double",
    ]
    /// The client-minted stream a stream-scoped request runs on (design 3.1); nil is the control sequence.
    static var streamField: WireType.Field {
        WireType.Field(
            wire: "stream", swift: "stream", type: .named("UInt16"), required: false, nullable: true, omitNil: true,
            defaultValue: nil,
            description: "The stream this request runs on (attach-streams-v1); nil is the control sequence."
        )
    }

    let commands: [RequestCommand]
    /// Where the generated coder's keys differ from the old snake-case encoder's.
    let inventory: WireKeyInventory

    init(sdkSchema: Data, client: String = MethodTableSchema.macOSClient) throws(RequestSchemaError) {
        let document: SchemaJSON
        do {
            document = try JSONDecoder().decode(SchemaJSON.self, from: sdkSchema)
        } catch {
            throw RequestSchemaError(path: "$", message: "not JSON: \(error)")
        }
        try self.init(document: document, client: client)
    }

    init(document: SchemaJSON, client: String = MethodTableSchema.macOSClient) throws(RequestSchemaError) {
        guard let entries = document["commands"]?.object else {
            throw RequestSchemaError(path: "$.commands", message: "must be an object")
        }
        var families: [UInt8: String] = [:]
        for (name, family) in document["families"]?.object ?? [:] {
            if let raw = family["id"]?.integer, let id = UInt8(exactly: raw) { families[id] = name }
        }
        let types = document["types"]?.object ?? [:]
        let reader = RequestTypeReader(types: types)
        var commands: [RequestCommand] = []
        var requests: [(wire: String, request: SchemaJSON)] = []
        var owners: [String: String] = [:]
        for wire in entries.keys.sorted() {
            guard let node = entries[wire] else { continue }
            let path = "$.commands.\(wire)"
            guard try Self.serves(node, client: client, path: path) else { continue }
            let command = try Self.command(wire, node: node, path: path, reader: reader, families: families)
            if let other = owners.updateValue(wire, forKey: command.typeName) {
                throw RequestSchemaError(path: path, message: "\(command.typeName) is also \"\(other)\"'s name")
            }
            commands.append(command)
            if let request = node["request"] { requests.append((wire: wire, request: request)) }
        }
        self.commands = commands
        inventory = WireKeyInventory(types: types, requests: requests)
    }

    /// Whether `client` calls the command (design 3.3: Swift generates only methods whose
    /// `clients` include macos). A command must name its clients: absent is refused, not
    /// read as every client, so a new command never gets a macOS type by omission.
    private static func serves(_ node: SchemaJSON, client: String, path: String) throws(RequestSchemaError) -> Bool {
        guard case .array(let items)? = node["clients"], !items.isEmpty, items.allSatisfy({ $0.string != nil }) else {
            throw RequestSchemaError(path: "\(path).clients", message: "must be a non-empty array of client names")
        }
        return items.contains(.string(client))
    }

    private static func command(
        _ wire: String,
        node: SchemaJSON,
        path: String,
        reader: RequestTypeReader,
        families: [UInt8: String]
    ) throws(RequestSchemaError) -> RequestCommand {
        let typeName = (typeNames[wire] ?? SwiftNaming.typeName(wire)) + "Request"
        var methodID: UInt16?
        if let value = node["method_id"] {
            guard let raw = value.integer, let id = UInt16(exactly: raw) else {
                throw RequestSchemaError(path: "\(path).method_id", message: "must be a u16")
            }
            methodID = id
        }
        let family = methodID.map { id in
            let byte = UInt8(truncatingIfNeeded: id >> 8)
            return families[byte] ?? SwiftNaming.hex(byte)
        }
        guard let request = node["request"] else { throw RequestSchemaError(path: path, message: "needs a request") }
        var fields = try reader.object(request, path: "\(path).request", name: typeName).fields
        if let envelope = fields.first(where: { envelopeKeys.contains($0.wire) }) {
            throw RequestSchemaError(path: "\(path).request.fields.\(envelope.wire)",
                                     message: "the line envelope owns \(envelope.wire)")
        }
        if try flag(node, "stream_scoped", path: path) {
            // A command whose daemon handler reads the stream itself (the attached-view commands
            // check it against the view's stream) declares it; the declaration must be the
            // envelope's stream, and the request sends it as the envelope does.
            if let declared = fields.firstIndex(where: { $0.swift == streamField.swift }) {
                let field = fields[declared]
                guard field.wire == streamField.wire, field.type == streamField.type, !field.required,
                      field.nullable
                else {
                    throw RequestSchemaError(
                        path: "\(path).request.fields.stream",
                        message: "a stream-scoped request has its own stream: declare it as an optional, "
                            + "nullable uint16 or not at all"
                    )
                }
                fields.remove(at: declared)
            }
            fields.append(streamField)
        }
        guard let result = node["result"] else { throw RequestSchemaError(path: path, message: "needs a result") }
        let response: WireType
        switch result["kind"]?.string ?? "" {
        case "object": response = .object(try reader.object(result, path: "\(path).result", name: "Response"))
        case "ref" where result["name"]?.string == "EmptyResult": response = .named("EmptyResponse")
        // A document the daemon writes whole (trace-status): JSONValue, as a ref to an
        // opaque_json type is. Only a result: an inline opaque request member would hide its
        // keys from WireKeyInventory, so the reader still refuses it.
        case "opaque_json": response = .json(schema: "\(path).result")
        default: response = try reader.type(result, path: "\(path).result", field: "", nested: "Response")
        }
        let spawnsTerminal = try flag(node, "spawns_terminal", path: path)
        return RequestCommand(
            wire: wire, typeName: typeName, methodID: methodID, family: family ?? "unframed",
            spawnsTerminal: spawnsTerminal, fields: fields, response: response
        )
    }

    static func flag(_ node: SchemaJSON, _ key: String, path: String) throws(RequestSchemaError) -> Bool {
        guard let value = node[key] else { return false }
        guard let set = value.bool else {
            throw RequestSchemaError(path: "\(path).\(key)", message: "must be a boolean")
        }
        return set
    }
}
