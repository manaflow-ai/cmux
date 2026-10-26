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
     "shape.get": {"class": "read", "idempotency": "forbidden", "errors": ["validation.invalid"],
       "params": {"selectors": {"machine": "required", "session": "required"}, "fields": {}, "extra": false},
       "result": {"kind": "ref", "name": "Shape"}},
     "cli.only": {"class": "read", "idempotency": "forbidden", "errors": ["validation.invalid"], "clients": ["cli"],
       "params": {"selectors": {"machine": "required", "session": "required"}, "fields": {}, "extra": false},
       "result": {"kind": "ref", "name": "CliThing"}}}
    """#

/// The `cmux.protocol/2` bindings generator (p05-ipc-024): typed params and results per
/// operation the app calls, the catalog's errors with typed details, open enums, tagged unions,
/// and refusals that name the catalog place. The byte goldens of the generated types (3 ops
/// encode to today's lines) are ResourceRequestLineTests in CmuxNextIPCTests.
@Suite struct ResourceEmitterTests {
    private static func shapes() throws -> ResourceEmitter {
        try ResourceEmitter(catalog: catalog(types: shapeTypes, operations: shapeOperations))
    }

    @Test func keepsTheMacOSOperationsAndWhatTheyReach() throws {
        let emitter = try Self.shapes()
        #expect(emitter.operationNames == ["shape.get", "terminal.input.write"])
        // CliThing is only cli.only's result.
        #expect(emitter.typeNames == ["Circle", "EmptyResult", "MutationResult", "Shape"])
        #expect(try emitter.declarations().map(\.name) == [
            "V2MachineID", "V2SessionID", "V2TerminalID",
            "V2Circle", "V2EmptyResult", "V2MutationResult", "V2Shape",
            "V2ValidationInvalidDetails", "V2ResourceError",
            "V2ShapeGetRequest", "V2TerminalInputWriteRequest",
        ])
    }

    @Test func emitsATypedMutationRequest() throws {
        let source = try Self.shapes().source()
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

    @Test func emitsObjectsGenericsUnionsAndErrors() throws {
        let source = try Self.shapes().source()
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
        #expect(source.contains("""
                        self.details = .validationInvalid(try container.decode(V2ValidationInvalidDetails.self, forKey: .details))
            """))
        #expect(source.contains("extension ResourceOperationRequest {"))
        // Objects decode; requests only encode.
        #expect(source.components(separatedBy: "public init(from decoder: any Decoder) throws {").count - 1 == 6)
        #expect(!source.contains("keyEncodingStrategy") && !source.contains("keyDecodingStrategy"))
        #expect(!source.contains("try!") && !source.contains("JSONEncoder") && !source.contains("JSONDecoder"))
    }

    @Test func emitsTheSameBytesEveryRun() throws {
        #expect(try Self.shapes().source() == Self.shapes().source())
        let real = try specData("resource-operations-v2.json")
        #expect(try ResourceEmitter(resourceOperations: real).source() == ResourceEmitter(resourceOperations: real).source())
    }

    /// The real catalog: a request per operation the app calls (every one, while no operation is
    /// tagged with `clients`), the catalog's 28 errors, and no refusal.
    @Test func coversTheRealCatalog() throws {
        let data = try specData("resource-operations-v2.json")
        let catalog = try ResourceCatalog(data: data)
        let emitter = try ResourceEmitter(catalog: catalog)
        #expect(emitter.operationNames == catalog.operationNames(client: "macos"))
        #expect(!emitter.operationNames.isEmpty)
        let source = try emitter.source()
        #expect(source.components(separatedBy: "    public static let resourceOperation = ").count - 1
            == emitter.operationNames.count)
        let errors = try emitter.errorCases().cases
        #expect(errors.count == 28 && errors.map(\.code) == catalog.errors.keys.sorted())
        #expect(errors.contains(ResourceEmitter.ErrorCase(code: "selector.ambiguous", caseName: "selectorAmbiguous",
                                                          detailsType: "V2SelectorAmbiguousDetails")))
        #expect(source.contains("public struct V2TerminalInputWriteRequest: ResourceMutationRequest, Equatable {"))
        #expect(source.contains("public struct V2SessionEventsRequest: ResourceStreamRequest, Equatable {"))
        #expect(source.contains("public typealias V2JsonValue = ResourceJSON\n"))
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
            (#"{"a.get": {\#(read), "result": {"kind": "ref", "name": "EmptyResult"}, "params": {\#(selectors),
                "fields": {"tab_name": {"required": true, "type": {"kind": "primitive", "name": "string"}},
                           "tab.name": {"required": true, "type": {"kind": "primitive", "name": "string"}}}}}}"#,
             #"{"EmptyResult": {"kind": "object", "fields": {}, "extra": false}}"#,
             .nameCollision(path: "$.operations.a.get.params", swiftName: "tabName")),
            (#"{"a.get": {\#(read), "result": {"kind": "ref", "name": "EmptyResult"},
                "params": {"selectors": {"planet": "required"}, "fields": {}, "extra": false}}}"#,
             #"{"EmptyResult": {"kind": "object", "fields": {}, "extra": false}}"#,
             .unsupported(path: "$.operations.a.get.params.selectors.planet", reason: "not a resource scope")),
            (#"{"a.get": {\#(read), "params": {\#(selectors), "fields": {}},
                "result": {"kind": "primitive", "name": "uint8"}}}"#,
             "{}", .unsupported(path: "$.operations.a.get.result", reason: "unknown primitive uint8")),
            (#"{"a.b_c": {\#(read), "params": {\#(selectors), "fields": {}}, "result": {"kind": "primitive", "name": "string"}},
                "a_b.c": {\#(read), "params": {\#(selectors), "fields": {}}, "result": {"kind": "primitive", "name": "string"}}}"#,
             "{}", .nameCollision(path: "$", swiftName: "V2ABCRequest")),
            (#"{"a.get": {\#(read), "params": {\#(selectors), "fields": {}}, "result": {"kind": "ref", "name": "Shape"}}}"#,
             #"{"Plain": {"kind": "object", "fields": {}, "extra": false},
                "Shape": {"kind": "union", "discriminator": "kind", "variants": [{"kind": "ref", "name": "Plain"}]}}"#,
             .unsupported(path: "$.types.Shape.variants[0]",
                          reason: "a tagged variant must name an object whose required kind is an enum of its tags")),
        ]
        for (operations, types, expected) in refusals {
            #expect(throws: expected, "\(operations)") {
                try ResourceEmitter(catalog: catalog(types: types, operations: operations)).source()
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
