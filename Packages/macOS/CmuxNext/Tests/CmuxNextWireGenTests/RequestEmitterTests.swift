import Foundation
import Testing
@testable import CmuxNextWireGen

private func repositoryFile(_ path: String) throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appendingPathComponent(path))
}

private func json(_ text: String) throws -> SchemaJSON {
    try JSONDecoder().decode(SchemaJSON.self, from: Data(text.utf8))
}

/// RequestEmitter (p05-ipc task 021): one `<Name>Request` per `clients: macos` command of
/// cmux-tui/spec/sdk-schema.json, with explicit CodingKeys, its Response, and nothing of
/// the MethodTable's (id, priority, capability).
@Suite struct RequestEmitterTests {
    private static func liveSchema() throws -> RequestSchema {
        try RequestSchema(sdkSchema: repositoryFile("cmux-tui/spec/sdk-schema.json"))
    }

    // The live schema -------------------------------------------------------

    @Test func emitsOneTypePerMacOSCommand() throws {
        let document = try json(String(decoding: repositoryFile("cmux-tui/spec/sdk-schema.json"), as: UTF8.self))
        let all = try #require(document["commands"]?.object)
        // A command without `clients` is refused, never generated (design 3.3).
        let macOS = all.filter { _, node in
            guard case .array(let clients)? = node["clients"] else { return false }
            return clients.contains(.string("macos"))
        }
        let schema = try RequestSchema(document: document)
        #expect(schema.commands.map(\.wire) == macOS.keys.sorted())
        #expect(Set(schema.commands.map(\.typeName)).count == schema.commands.count)

        let sources = RequestEmitter(schema: schema).files().map(\.source).joined()
        for command in schema.commands {
            let declarations = sources.components(separatedBy: "public struct \(command.typeName): ").count - 1
            #expect(declarations == 1, "\(command.typeName)")
        }
        // The MethodTable holds the id, priority and capability: a request's only static is its name.
        #expect(sources.components(separatedBy: "public static ").count - 1 == schema.commands.count)
        #expect(sources.components(separatedBy: "public static let commandName: ").count - 1 == schema.commands.count)
        #expect(!sources.contains("keyEncodingStrategy"))
    }

    @Test func emitsTheSameBytesEveryRun() throws {
        let first = RequestEmitter(schema: try Self.liveSchema()).files()
        let second = RequestEmitter(schema: try Self.liveSchema()).files()
        #expect(first == second)
        #expect(first.contains { $0.name == "Requests+TerminalIO.swift" })
    }

    // Shapes ------------------------------------------------------------------

    private static let fixture = #"""
    {
      "families": {"tabs": {"id": 7}},
      "types": {
        "Id": {"kind": "alias", "target": {"kind": "scalar", "name": "uint64"}},
        "Base64": {"kind": "alias", "target": {"kind": "scalar", "name": "string"}},
        "JsonValue": {"kind": "opaque_json", "reason": "a document"},
        "TabRef": {"kind": "opaque_json", "reason": "a number or a string"},
        "EmptyResult": {"kind": "object", "fields": {}, "additional_properties": false},
        "SurfaceResult": {"kind": "object", "fields": {}, "additional_properties": false}
      },
      "commands": {
        "new-tab": {
          "method_id": 1792, "spawns_terminal": true, "stream_scoped": true, "clients": ["macos", "cli"],
          "request": {"kind": "object", "additional_properties": false, "fields": {
            "surface": {"type": {"kind": "ref", "name": "Id"}, "presence": "required", "nullable": false},
            "kind": {"type": {"kind": "literal", "value": "tab"}, "presence": "required", "nullable": false},
            "transport": {"type": {"kind": "ref", "name": "JsonValue"}, "presence": "required", "nullable": true},
            "env": {"type": {"kind": "map", "values": {"kind": "scalar", "name": "string"}},
                    "presence": "optional", "nullable": true, "description": "Extra environment."},
            "mode": {"type": {"kind": "enum", "values": ["toggle", "on", "default"], "fallback": "toggle"},
                     "presence": "optional", "nullable": false, "default": "toggle"},
            "target": {"type": {"kind": "ref", "name": "TabRef"}, "presence": "optional", "nullable": false},
            "bytes": {"type": {"kind": "ref", "name": "Base64"}, "presence": "optional", "nullable": true,
                      "capability": "bytes-v1"},
            "hint": {"type": {"kind": "scalar", "name": "string"}, "presence": "optional", "nullable": true,
                     "omit_nil": true}
          }},
          "result": {"kind": "ref", "name": "SurfaceResult"}
        },
        "list-tabs": {
          "method_id": 1793, "clients": ["macos"],
          "request": {"kind": "object", "fields": {}, "additional_properties": false},
          "result": {"kind": "object", "additional_properties": false, "fields": {
            "count": {"type": {"kind": "scalar", "name": "uint32"}, "presence": "optional", "nullable": false,
                      "default": 0},
            "type": {"type": {"kind": "literal", "value": "run.live"}, "presence": "required", "nullable": false},
            "cursor": {"type": {"kind": "scalar", "name": "string"}, "presence": "required", "nullable": true},
            "items": {"type": {"kind": "array", "items": {"kind": "object", "additional_properties": false,
                        "fields": {"id": {"type": {"kind": "scalar", "name": "string"}, "presence": "required",
                                          "nullable": false}}}},
                      "presence": "optional", "nullable": false, "default": []}
          }}
        },
        "close-tab": {
          "method_id": 1794, "clients": ["macos"],
          "request": {"kind": "object", "fields": {}, "additional_properties": false},
          "result": {"kind": "ref", "name": "EmptyResult"}
        },
        "tab-inventory": {
          "method_id": 1795, "clients": ["cli"],
          "request": {"kind": "object", "fields": {}, "additional_properties": false},
          "result": {"kind": "ref", "name": "EmptyResult"}
        },
        "agent-cli-update-job": {
          "clients": ["macos", "cli"],
          "request": {"kind": "object", "fields": {}, "additional_properties": false},
          "result": {"kind": "ref", "name": "JsonValue"}
        }
      }
    }
    """#

    private static func fixtureSchema() throws -> RequestSchema {
        try RequestSchema(document: json(fixture))
    }

    private static func source(_ wire: String) throws -> String {
        let schema = try fixtureSchema()
        let command = try #require(schema.commands.first { $0.wire == wire })
        return RequestEmitter(schema: schema).source(for: command)
    }

    @Test func keepsOnlyTheMacOSCommands() throws {
        let schema = try Self.fixtureSchema()
        #expect(schema.commands.map(\.typeName)
            == ["AgentCLIUpdateJobRequest", "CloseTabRequest", "ListTabsRequest", "NewTabRequest"])
        #expect(schema.commands.map(\.family) == ["unframed", "tabs", "tabs", "tabs"])
        let cli = try RequestSchema(document: json(Self.fixture), client: "cli")
        #expect(cli.commands.map(\.wire).contains("tab-inventory"))
    }

    @Test func aRequestWritesItsKeysAndConstants() throws {
        let source = try Self.source("new-tab")
        for line in [
            "/// `new-tab` (method 0x0700, family `tabs`).",
            "public struct NewTabRequest: TerminalSpawningRequest, Equatable {",
            "    public typealias Response = SurfaceResult\n",
            // Required members first, then optional ones; the constant has no property. An optional
            // nullable member is a FieldUpdate; an omit_nil or non-nullable one stays optional.
            "public init(surface: SurfaceID, transport: JSONValue?, bytes: FieldUpdate<Data> = .unchanged, "
                + "env: FieldUpdate<[String: String]> = .unchanged, hint: String? = nil, mode: Mode? = nil, "
                + "target: JSONValue? = nil, stream: UInt16? = nil) {",
            "    /// Extra environment.\n    public var env: FieldUpdate<[String: String]>\n",
            "/// Daemon capability `bytes-v1`.",
            "try container.encode(\"tab\" as String, forKey: .kind)",
            "try container.encode(self.surface, forKey: .surface)",
            // A required nullable member writes null; an optional one is left out when nil.
            "try container.encode(self.transport, forKey: .transport)",
            "try container.encodeIfPresent(self.hint, forKey: .hint)",
            "try container.encodeIfPresent(self.target, forKey: .target)",
            "try container.encodeIfPresent(self.stream, forKey: .stream)",
            // A FieldUpdate leaves the key out unchanged, writes null to clear, the value when set.
            """
                    switch self.env {
                    case .unchanged: break
                    case .clear: try container.encodeNil(forKey: .env)
                    case .set(let value): try container.encode(value, forKey: .env)
                    }

            """,
            "public enum Mode: String, Codable, Sendable, Equatable, CaseIterable {",
            "case `default`",
            "self = Self(rawValue: raw) ?? .toggle",
        ] {
            #expect(source.contains(line), "\(line)")
        }
        #expect(!source.contains("public var kind"))
    }

    @Test func aResponseReadsDefaultsNullsAndConstants() throws {
        let source = try Self.source("list-tabs")
        for line in [
            "public struct ListTabsRequest: DaemonRequest, Equatable {",
            "public struct Response: Decodable, Sendable, Equatable {",
            "public struct ItemsItem: Decodable, Sendable, Equatable {",
            "public init(cursor: String?, type: String = \"run.live\", count: UInt32 = 0, items: [ItemsItem] = []) {",
            "self.cursor = try container.decode(Optional<String>.self, forKey: .cursor)",
            "self.count = try container.decodeIfPresent(UInt32.self, forKey: .count) ?? 0",
            "self.items = try container.decodeIfPresent([ItemsItem].self, forKey: .items) ?? []",
            "let value = try container.decode(String.self, forKey: .type)",
            "guard value == \"run.live\" else {",
            "self.id = try container.decode(String.self, forKey: .id)",
            // The request has no member: it adds no key to the envelope's.
            "public init() {",
            "public func encode(to encoder: any Encoder) throws {}",
        ] {
            #expect(source.contains(line), "\(line)")
        }
        #expect(!source.contains("typealias Response"))
    }

    @Test func emptyAndOpaqueResultsUseTheSharedTypes() throws {
        #expect(try Self.source("close-tab").contains("public typealias Response = EmptyResponse\n"))
        let unframed = try Self.source("agent-cli-update-job")
        #expect(unframed.contains("public typealias Response = JSONValue\n"))
        #expect(unframed.contains("/// `agent-cli-update-job` (family `unframed`)."))
    }

    @Test func groupsFilesByFamilyAndImportsFoundationOnlyForData() throws {
        let files = RequestEmitter(schema: try Self.fixtureSchema()).files()
        #expect(files.map(\.name) == ["Requests+Tabs.swift", "Requests+Unframed.swift"])
        #expect(files[0].source.contains("\npublic import Foundation\n"))
        #expect(!files[1].source.contains("import Foundation"))
        #expect(files[0].source.hasPrefix("// Generated by CmuxNextWireGen (RequestEmitter)"))
    }

    @Test func namesFollowTheBindingsWordsWithSwiftInitialisms() {
        #expect(SwiftNaming.typeName("agent-cli-update-job") == "AgentCLIUpdateJob")
        #expect(SwiftNaming.typeName("terminal-io") == "TerminalIO")
        #expect(SwiftNaming.propertyName("terminal_id") == "terminalID")
        #expect(SwiftNaming.propertyName("session_ids") == "sessionIDs")
        #expect(SwiftNaming.propertyName("mimeType") == "mimeType")
        #expect(SwiftNaming.words("HTTPServer2Go") == ["http", "server2", "go"])
        #expect(SwiftNaming.identifier("default") == "`default`")
        #expect(SwiftNaming.typeName("3d-view") == "_3dView")
    }

    /// A stream-scoped command whose handler reads `stream` declares it (detach-attached-view):
    /// the declared member is the envelope's stream, emitted once, the way the envelope sends it.
    @Test func aDeclaredStreamOfAStreamScopedCommandIsTheEnvelopesStream() throws {
        let uint16 = #"{"kind": "scalar", "name": "uint16"}"#
        let document = try json(
            #"{"families": {}, "types": {}, "commands": {"detach-view": {"clients": ["macos"], "stream_scoped": true, "#
                + #""request": {"kind": "object", "fields": {"stream": {"type": \#(uint16), "presence": "optional", "#
                + #""nullable": true, "default": null, "constraints": ["The view's stream."]}}}, "#
                + #""result": {"kind": "object", "fields": {}, "additional_properties": false}}}}"#
        )
        let command = try #require(try RequestSchema(document: document).commands.first)
        #expect(command.fields == [RequestSchema.streamField])
    }

    /// A result the schema gives as an inline `opaque_json` (trace-start, trace-stop and
    /// trace-status, which the app calls) is a JSON document: its Response is JSONValue,
    /// as the hand-written DaemonTraceLink requests have it.
    @Test func anInlineOpaqueResultIsAJSONValueResponse() throws {
        let document = try json(
            #"{"families": {}, "types": {}, "commands": {"trace-status": {"clients": ["macos"], "#
                + #""request": {"kind": "object", "fields": {}, "additional_properties": false}, "#
                + #""result": {"kind": "opaque_json", "reason": "The recorder's own report."}}}}"#
        )
        let command = try #require(try RequestSchema(document: document).commands.first)
        #expect(command.response.swift == "JSONValue")
    }

    // Refusals ----------------------------------------------------------------

    private static func refused(_ command: String, types: String = "{}") throws -> String {
        let document = try json(#"{"families": {}, "types": \#(types), "commands": {"a": \#(command)}}"#)
        do {
            _ = try RequestSchema(document: document)
        } catch {
            return error.description
        }
        Issue.record("not refused: \(command)")
        return ""
    }

    @Test func refusesWhatItCannotEmit() throws {
        let empty = #""result": {"kind": "object", "fields": {}, "additional_properties": false}"#
        let string = #"{"kind": "scalar", "name": "string"}"#
        let macOS = #""clients": ["macos"]"#
        let cases: [(command: String, expected: String)] = [
            (#"{\#(macOS), "request": {"kind": "object", "fields": {"id": {"type": \#(string), "presence": "required", "nullable": false}}}, \#(empty)}"#,
             "$.commands.a.request.fields.id: the line envelope owns id"),
            (#"{\#(macOS), "stream_scoped": true, "request": {"kind": "object", "fields": {"stream": {"type": \#(string), "presence": "optional", "nullable": true}}}, \#(empty)}"#,
             "has its own stream"),
            (#"{\#(macOS), "request": {"kind": "object", "fields": {"x": {"type": {"kind": "ref", "name": "Missing"}, "presence": "optional", "nullable": true}}}, \#(empty)}"#,
             "Missing is not in $.types"),
            (#"{\#(macOS), "request": {"kind": "object", "fields": {"a_b": {"type": \#(string), "presence": "optional", "nullable": true}, "aB": {"type": \#(string), "presence": "optional", "nullable": true}}}, \#(empty)}"#,
             "is aB in Swift"),
            (#"{\#(macOS), "request": {"kind": "object", "fields": {"x": {"type": \#(string), "presence": "sometimes", "nullable": true}}}, \#(empty)}"#,
             "must be required or optional"),
            (#"{\#(macOS), "request": {"kind": "ref", "name": "X"}, \#(empty)}"#, "must be an inline object"),
            (#"{\#(macOS), "request": {"kind": "object", "fields": {}}}"#, "needs a result"),
            // A command names its clients: absent is not "every client", so no type by omission.
            (#"{"request": {"kind": "object", "fields": {}}, \#(empty)}"#,
             "$.commands.a.clients: must be a non-empty array of client names"),
            (#"{"clients": [], "request": {"kind": "object", "fields": {}}, \#(empty)}"#,
             "$.commands.a.clients: must be a non-empty array of client names"),
        ]
        for (command, expected) in cases {
            let message = try Self.refused(command)
            #expect(message.contains(expected), "\(command): \(message)")
            #expect(message.hasPrefix("sdk-schema.json: "), "\(message)")
        }
    }
}
