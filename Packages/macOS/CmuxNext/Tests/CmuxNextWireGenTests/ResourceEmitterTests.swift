import Foundation
import Testing
@testable import CmuxNextWireGen

private func specData(_ file: String) throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/\(file)"))
}

/// A small catalog: `types` and `operations` are spliced in; the rest is fixed.
private func catalog(types: String = "{}", operations: String) throws -> ResourceCatalog {
    try ResourceCatalog(data: Data(#"""
        {"resource_scopes": ["machine", "session", "terminal"],
         "types": \#(types),
         "generics": {"MutationResult": {"parameters": ["T"], "body": {"kind": "object", "extra": false,
           "fields": {"value": {"required": true, "type": {"kind": "parameter", "name": "T"}}}}}},
         "errors": {"validation.invalid": {"retryable": false, "details": {"kind": "object", "extra": false,
           "fields": {"reason": {"required": true, "type": {"kind": "primitive", "name": "string"}}}}}},
         "operations": \#(operations)}
        """#.utf8))
}

private let shapeTypes = #"""
    {"EmptyResult": {"kind": "object", "fields": {}, "extra": false},
     "CliThing": {"kind": "object", "fields": {}, "extra": false},
     "Circle": {"kind": "object", "extra": false, "fields": {
       "kind": {"required": true, "type": {"kind": "enum", "values": ["circle"]}},
       "radius": {"required": true, "type": {"kind": "primitive", "name": "float64"}},
       "label": {"required": true, "type": {"kind": "nullable", "value": {"kind": "primitive", "name": "string"}}}}},
     "Shape": {"kind": "union", "discriminator": "kind", "variants": [{"kind": "ref", "name": "Circle"}],
       "unknown_variant": {"sdk_name": "Unknown", "when": "unrecognized_discriminator",
                           "preserve_discriminator": true, "preserve_raw_object": true}}}
    """#

private let shapeOperations = #"""
    {"terminal.input.write": {"class": "mutation", "idempotency": "required", "errors": ["validation.invalid"],
       "params": {"selectors": {"machine": "required", "session": "required", "terminal": "required"}, "extra": false,
         "fields": {"text": {"required": false, "type": {"kind": "primitive", "name": "string"}},
                    "class": {"required": false, "type": {"kind": "enum", "values": ["a", "public"]}}}},
       "result": {"kind": "apply", "name": "MutationResult", "arguments": [{"kind": "ref", "name": "EmptyResult"}]}},
     "notification.clear": {"class": "mutation", "idempotency": "required", "errors": ["validation.invalid"],
       "params": {"selectors": {"machine": "required", "session": "required"}, "fields": {}, "extra": false},
       "result": {"kind": "apply", "name": "MutationResult", "arguments": [{"kind": "ref", "name": "EmptyResult"}]}},
     "shape.get": {"class": "read", "idempotency": "forbidden", "errors": ["validation.invalid"],
       "params": {"selectors": {"machine": "required", "session": "required"}, "fields": {}, "extra": false},
       "result": {"kind": "ref", "name": "Shape"}},
     "cli.only": {"class": "read", "idempotency": "forbidden", "errors": ["validation.invalid"], "clients": ["cli"],
       "params": {"selectors": {"machine": "required", "session": "required"}, "fields": {}, "extra": false},
       "result": {"kind": "ref", "name": "CliThing"}}}
    """#

/// Every operation of `catalog`, for refusal cases that need no app list.
private func everyOperation(_ catalog: ResourceCatalog) throws -> ResourceEmitter {
    try ResourceEmitter(catalog: catalog, operations: Array(catalog.operations.keys))
}

/// All generated files as one text, for checks that do not care which file holds a declaration.
private func allSource(_ emitter: ResourceEmitter) throws -> String {
    try emitter.files().map(\.text).joined()
}

/// The `cmux.protocol/2` bindings generator: typed params and results for the
/// operations the app names, one file per family, the catalog's errors with typed details, open
/// enums, tagged unions, and refusals that name the catalog place. The byte goldens of the
/// generated types (3 ops encode to today's lines) are ResourceRequestLineTests in
/// CmuxNextIPCTests; CmuxNextDaemonTests' ResourceRequestLineParityTests compares the same calls
/// with today's `ResourceRequestEnvelope` bytes.
@Suite struct ResourceEmitterTests {
    private static let appOperations = ["shape.get", "terminal.input.write", "notification.clear"]

    private static func shapes() throws -> ResourceEmitter {
        try ResourceEmitter(catalog: catalog(types: shapeTypes, operations: shapeOperations), operations: appOperations)
    }

    /// Only the named operations, split by family; a type one family reaches is in that family's
    /// file, a type two families (or the errors) reach is in the shared file.
    @Test func splitsTheNamedOperationsByFamily() throws {
        let emitter = try Self.shapes()
        #expect(emitter.operationNames == ["notification.clear", "shape.get", "terminal.input.write"])
        #expect(emitter.sharedTypeNames == ["EmptyResult", "MutationResult"])
        #expect(emitter.families == [
            ResourceEmitter.Family(name: "notification", operationNames: ["notification.clear"], typeNames: []),
            ResourceEmitter.Family(name: "shape", operationNames: ["shape.get"], typeNames: ["Circle", "Shape"]),
            ResourceEmitter.Family(name: "terminal", operationNames: ["terminal.input.write"], typeNames: []),
        ])
        #expect(try emitter.sharedDeclarations().map(\.name) == [
            "V2MachineID", "V2SessionID", "V2TerminalID", "V2EmptyResult", "V2MutationResult",
            "V2ValidationInvalidDetails", "V2ResourceError",
        ])
        #expect(try emitter.declarations(of: emitter.families[1]).map(\.name)
            == ["V2Circle", "V2Shape", "V2ShapeGetRequest"])
        let files = try emitter.files()
        #expect(files.map(\.name) == [
            "ResourceOperations.swift", "ResourceOperations+notification.swift", "ResourceOperations+shape.swift",
            "ResourceOperations+terminal.swift",
        ])
        #expect(files[0].text.contains("public typealias Response = ResourceResponse<Self.Result, V2ResourceError>"))
        #expect(files[2].text.contains("public struct V2ShapeGetRequest: ResourceUnkeyedRequest, Equatable {"))
        #expect(!files[2].text.contains("V2TerminalInputWriteRequest") && !files[3].text.contains("struct V2Shape"))
        // CliThing is only the result of cli.only, which the app does not name.
        #expect(!files.contains { $0.text.contains("CliThing") })
    }

    @Test func refusesAnOperationTheAppCannotCall() throws {
        let shapes = try catalog(types: shapeTypes, operations: shapeOperations)
        #expect(throws: ResourceEmitterError.notForClient(operation: "cli.only", client: "macos")) {
            try ResourceEmitter(catalog: shapes, operations: ["cli.only"])
        }
        #expect(throws: ResourceEmitterError.unknownOperation("shape.list")) {
            try ResourceEmitter(catalog: shapes, operations: ["shape.get", "shape.list"])
        }
    }

    @Test func emitsATypedMutationRequest() throws {
        let source = try allSource(Self.shapes())
        #expect(source.contains("""
            /// `terminal.input.write` (mutation). Errors: `validation.invalid`.
            public struct V2TerminalInputWriteRequest: ResourceMutationRequest, Equatable {
                public static let resourceOperation = "terminal.input.write"
                public typealias Result = V2MutationResult<V2EmptyResult>

                public var machine: ResourceSelector
                public var session: ResourceSelector
                public var terminal: ResourceSelector
                public var `class`: Class?
                public var text: String?

                public struct Class: RawRepresentable, Codable, Hashable, Sendable {
                    public static let a = Class(rawValue: "a")
                    public static let `public` = Class(rawValue: "public")

            """))
        #expect(source.contains("""
                enum CodingKeys: String, CodingKey {
                    case machine = "machine"
                    case session = "session"
                    case terminal = "terminal"
                    case `class` = "class"
                    case text = "text"
                }

                public init(
                    machine: ResourceSelector = .current,
                    session: ResourceSelector = .current,
                    terminal: ResourceSelector,
                    `class`: Class? = nil,
                    text: String? = nil
                ) {
            """))
        #expect(source.contains("""
                    try container.encode(self.terminal, forKey: .terminal)
                    try container.encodeIfPresent(self.`class`, forKey: .`class`)
            """))
        #expect(source.contains("public struct V2ShapeGetRequest: ResourceUnkeyedRequest, Equatable {"))
        #expect(source.contains("    public typealias Result = V2Shape\n"))
    }

    /// An optional nullable request field has three states (absent keeps, `null` clears, a value
    /// sets), so it is a `ResourceFieldUpdate` defaulting to `.unchanged`, not an optional that
    /// cannot send `null`. A required nullable field and a plain optional one keep their spelling.
    @Test func emitsAnOptionalNullableRequestFieldAsAFieldUpdate() throws {
        let operations = #"""
            {"workspace.update": {"class": "mutation", "idempotency": "required", "errors": ["validation.invalid"],
               "params": {"selectors": {"machine": "required", "session": "required"}, "extra": false,
                 "fields": {"title": {"required": false, "type": {"kind": "nullable", "value": {"kind": "primitive", "name": "string"}}},
                            "path": {"required": true, "type": {"kind": "nullable", "value": {"kind": "primitive", "name": "string"}}},
                            "focus": {"required": false, "type": {"kind": "primitive", "name": "boolean"}},
                            "task_status": {"required": false, "type": {"kind": "nullable", "value": {"kind": "enum", "values": ["todo", "done"]}}}}},
               "result": {"kind": "apply", "name": "MutationResult", "arguments": [{"kind": "ref", "name": "EmptyResult"}]}}}
            """#
        let types = #"{"EmptyResult": {"kind": "object", "fields": {}, "extra": false}}"#
        let source = try allSource(ResourceEmitter(catalog: catalog(types: types, operations: operations),
                                                   operations: ["workspace.update"]))
        #expect(source.contains("""
                public var focus: Bool?
                public var path: String?
                public var taskStatus: ResourceFieldUpdate<TaskStatus>
                public var title: ResourceFieldUpdate<String>
            """))
        #expect(source.contains("""
                    focus: Bool? = nil,
                    path: String?,
                    taskStatus: ResourceFieldUpdate<TaskStatus> = .unchanged,
                    title: ResourceFieldUpdate<String> = .unchanged
                ) {
            """))
        #expect(source.contains("""
                    try container.encodeIfPresent(self.focus, forKey: .focus)
                    try container.encode(self.path, forKey: .path)
                    try self.taskStatus.encode(into: &container, forKey: .taskStatus)
                    try self.title.encode(into: &container, forKey: .title)
            """))
    }

    @Test func emitsObjectsGenericsUnionsAndErrors() throws {
        let source = try allSource(Self.shapes())
        #expect(source.contains("public struct V2MutationResult<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {"))
        #expect(source.contains("        self.value = try container.decode(T.self, forKey: .value)\n"))
        // A required nullable field is always written, null included; it decodes with decode(T?.self).
        #expect(source.contains("        self.label = try container.decode(String?.self, forKey: .label)\n"))
        #expect(source.contains("        try container.encode(self.label, forKey: .label)\n"))
        #expect(source.contains("""
            public indirect enum V2Shape: Codable, Sendable, Equatable {
                case circle(V2Circle)
                /// A tag this build does not know, with the complete raw object.
                case unknown(tag: String, raw: ResourceJSON)
            """))
        #expect(source.contains("        case \"circle\": self = .circle(try V2Circle(from: decoder))\n"))
        #expect(source.contains("        default: self = .unknown(tag: tag, raw: try ResourceJSON(from: decoder))\n"))
        #expect(source.contains("        case validationInvalid(V2ValidationInvalidDetails)\n"))
        // A known code whose details have another shape still keeps code, message and retryable.
        #expect(source.contains("""
                    case "validation.invalid":
                        if let value = try? container.decode(V2ValidationInvalidDetails.self, forKey: .details) {
                            self.details = .validationInvalid(value)
                        } else {
                            self.details = .malformed(try container.decode(ResourceJSON.self, forKey: .details))
                        }
            """))
        #expect(source.contains("        case malformed(ResourceJSON)\n"))
        #expect(source.contains("extension ResourceOperationRequest {"))
        // Objects decode; requests only encode.
        #expect(source.components(separatedBy: "public init(from decoder: any Decoder) throws {").count - 1 == 6)
        #expect(!source.contains("keyEncodingStrategy") && !source.contains("keyDecodingStrategy"))
        #expect(!source.contains("try!") && !source.contains("JSONEncoder") && !source.contains("JSONDecoder"))
    }

    @Test func emitsTheSameBytesEveryRun() throws {
        #expect(try Self.shapes().files() == Self.shapes().files())
        // The order the names come in does not matter.
        let reversed = try ResourceEmitter(catalog: catalog(types: shapeTypes, operations: shapeOperations),
                                           operations: Self.appOperations.reversed())
        #expect(try reversed.files() == Self.shapes().files())
        let real = try ResourceCatalog(data: specData("resource-operations-v2.json"))
        #expect(try everyOperation(real).files() == everyOperation(real).files())
    }

    /// The real catalog: every operation spells (so adding any of them to the app's list builds),
    /// a request per operation, the catalog's 28 errors, and no refusal.
    @Test func coversTheRealCatalog() throws {
        let catalog = try ResourceCatalog(data: specData("resource-operations-v2.json"))
        let emitter = try everyOperation(catalog)
        #expect(emitter.operationNames == catalog.operations.keys.sorted())
        let source = try allSource(emitter)
        #expect(source.components(separatedBy: "    public static let resourceOperation = ").count - 1
            == emitter.operationNames.count)
        let errors = try emitter.errorCases().cases
        #expect(errors.count == 28 && errors.map(\.code) == catalog.errors.keys.sorted())
        #expect(errors.contains(ResourceEmitter.ErrorCase(code: "selector.ambiguous", caseName: "selectorAmbiguous",
                                                          detailsType: "V2SelectorAmbiguousDetails")))
        #expect(source.contains("public struct V2TerminalInputWriteRequest: ResourceMutationRequest, Equatable {"))
        #expect(source.contains("public struct V2SessionEventsRequest: ResourceStreamRequest, Equatable {"))
        #expect(source.contains("public typealias V2JsonValue = ResourceJSON\n"))
        // `local.io` gets SwiftNaming's initialisms, as the v1 bindings spell `io`.
        #expect(errors.contains(ResourceEmitter.ErrorCase(code: "local.io", caseName: "localIO",
                                                          detailsType: "V2LocalIODetails")))
    }

    /// The three golden operations of ResourceRequestLineTests alone: a file per family, and the
    /// shared file holds the ids and the errors.
    @Test func splitsTheRealCatalogsGoldenOperations() throws {
        let catalog = try ResourceCatalog(data: specData("resource-operations-v2.json"))
        let emitter = try ResourceEmitter(catalog: catalog,
                                          operations: ["terminal.input.write", "notification.clear", "screen.get"])
        let files = try emitter.files()
        #expect(files.map(\.name) == [
            "ResourceOperations.swift", "ResourceOperations+notification.swift", "ResourceOperations+screen.swift",
            "ResourceOperations+terminal.swift",
        ])
        #expect(files[0].text.contains("public struct V2ResourceError: Error, Codable, Sendable, Equatable {"))
        #expect(files[0].text.contains("public struct V2TerminalID: ResourceIdentifier {"))
        #expect(files[2].text.contains("public struct V2ScreenGetRequest: ResourceUnkeyedRequest, Equatable {"))
        #expect(files[3].text.contains("public struct V2TerminalInputWriteRequest: ResourceMutationRequest, Equatable {"))
        #expect(!files.contains { $0.text.contains("V2SessionEventsRequest") })
    }

    @Test func namesFollowSwiftConventions() throws {
        func member(_ name: String) throws -> String { try ResourceSwiftName.member(name, path: "$").spelling }
        #expect(try member("terminal_id") == "terminalID")
        #expect(try member("tab_ids") == "tabIDs")
        #expect(try member("open_url") == "openURL")
        #expect(try member("class") == "`class`")
        #expect(try member("self") == "selfValue")
        #expect(try member("raw_value") == "rawValueValue")
        #expect(try member("image/png") == "imagePng")
        #expect(try member("state_upsert") == "stateUpsert")
        #expect(try ResourceSwiftName.upperCamel("terminal.input.write", path: "$") == "TerminalInputWrite")
        #expect(try ResourceSwiftName.nestedType("result", path: "$") == "ResultValue")
        #expect(try ResourceSwiftName.nestedType("layout", path: "$") == "Layout")
        #expect(try ResourceSwiftName.identifier(scope: "frontend_projection", path: "$") == "V2FrontendProjectionID")
        // SwiftNaming's words: camelCase and capital runs split; `api`, `cli` and `io` are initialisms.
        #expect(try member("HTTPServer") == "httpServer")
        #expect(try member("cli_api") == "cliAPI")
        #expect(try ResourceSwiftName.upperCamel("local.io", path: "$") == "LocalIO")
        #expect(throws: ResourceEmitterError.unsupported(path: "$", reason: "`2fa` has no Swift name")) {
            try ResourceSwiftName.member("2fa", path: "$")
        }
    }

    @Test func refusesWhatSwiftCannotSpell() throws {
        let read = #""class": "read", "idempotency": "forbidden", "errors": ["validation.invalid"]"#
        let selectors = #""selectors": {"machine": "required", "session": "required"}, "extra": false"#
        let refusals: [(operations: String, types: String, expected: ResourceEmitterError)] = [
            (#"{"a.get": {\#(read), "params": {\#(selectors), "fields": {}}, "result": {"kind": "ref", "name": "Missing"}}}"#,
             "{}", .unknownType("Missing")),
            (#"""
                  {"a.get": {\#(read), "result": {"kind": "ref", "name": "EmptyResult"}, "params": {\#(selectors),
                  "fields": {"tab_name": {"required": true, "type": {"kind": "primitive", "name": "string"}},
                  "tab.name": {"required": true, "type": {"kind": "primitive", "name": "string"}}}}}}
              """#,
             #"{"EmptyResult": {"kind": "object", "fields": {}, "extra": false}}"#,
             .nameCollision(path: "$.operations.a.get.params", swiftName: "tabName")),
            (#"""
                  {"a.get": {\#(read), "result": {"kind": "ref", "name": "EmptyResult"},
                  "params": {"selectors": {"planet": "required"}, "fields": {}, "extra": false}}}
              """#,
             #"{"EmptyResult": {"kind": "object", "fields": {}, "extra": false}}"#,
             .unsupported(path: "$.operations.a.get.params.selectors.planet", reason: "not a resource scope")),
            (#"""
                  {"a.get": {\#(read), "params": {\#(selectors), "fields": {}},
                  "result": {"kind": "primitive", "name": "uint8"}}}
              """#,
             "{}", .unsupported(path: "$.operations.a.get.result", reason: "unknown primitive uint8")),
            (#"""
                  {"a.b_c": {\#(read), "params": {\#(selectors), "fields": {}}, "result": {"kind": "primitive", "name": "string"}},
                  "a_b.c": {\#(read), "params": {\#(selectors), "fields": {}}, "result": {"kind": "primitive", "name": "string"}}}
              """#,
             "{}", .nameCollision(path: "$", swiftName: "V2ABCRequest")),
            (#"{"a.get": {\#(read), "params": {\#(selectors), "fields": {}}, "result": {"kind": "ref", "name": "Shape"}}}"#,
             #"""
                  {"Plain": {"kind": "object", "fields": {}, "extra": false},
                  "Shape": {"kind": "union", "discriminator": "kind", "variants": [{"kind": "ref", "name": "Plain"}]}}
              """#,
             .unsupported(path: "$.types.Shape.variants[0]",
                          reason: "a tagged variant must name an object whose required kind is an enum of its tags")),
            // An idempotency the envelope builder has no protocol for, and a stream with a key.
            (#"""
                  {"a.set": {"class": "mutation", "idempotency": "optional", "errors": [], "params": {\#(selectors),
                  "fields": {}}, "result": {"kind": "primitive", "name": "string"}}}
              """#,
             "{}", .unsupported(path: "$.operations.a.set.idempotency",
                                reason: "idempotency is required or forbidden, not optional")),
            (#"""
                  {"a.watch": {"class": "stream_open", "idempotency": "required", "errors": [], "params": {\#(selectors),
                  "fields": {}}, "result": {"kind": "primitive", "name": "string"},
                  "stream": {"item": {"kind": "primitive", "name": "string"}, "end": {"kind": "primitive", "name": "string"}}}}
              """#,
             "{}", .unsupported(path: "$.operations.a.watch.idempotency", reason: "a stream takes no idempotency key")),
            // A family is a file name.
            (#"""
                  {"Tab-Group.get": {\#(read), "params": {\#(selectors), "fields": {}},
                  "result": {"kind": "primitive", "name": "string"}}}
              """#,
             "{}", .unsupported(path: "$.operations.Tab-Group.get", reason: "its family `Tab-Group` is not a file name")),
        ]
        for (operations, types, expected) in refusals {
            #expect(throws: expected, "\(operations)") {
                try everyOperation(catalog(types: types, operations: operations)).files()
            }
        }
    }

    @Test func refusesAnUnreadableCatalog() {
        #expect(throws: ResourceEmitterError.self) { try ResourceCatalog(data: Data(#"{"operations": {}}"#.utf8)) }
        do {
            _ = try ResourceCatalog(data: Data("[]".utf8))
            Issue.record("not refused")
        } catch {
            #expect("\(error)".hasPrefix("resource-operations-v2.json: not an operation catalog"))
        }
    }
}
