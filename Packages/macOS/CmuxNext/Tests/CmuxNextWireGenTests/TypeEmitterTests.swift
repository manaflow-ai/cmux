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

/// TypeEmitter (p05-ipc-020): the Swift wire types the `clients: macos`
/// commands reach, read from cmux-tui/spec/fixtures/ipc-wire-types and from
/// the real cmux-tui/spec/sdk-schema.json. Six shapes are compared with their
/// golden text (TypeEmitterGolden); the behavior of the real output is
/// CmuxNextIPCTests' WireTypesTests.
@Suite struct TypeEmitterTests {
    private static func fixture() throws -> TypeEmitter {
        try TypeEmitter(sdkSchema: repositoryFile("cmux-tui/spec/fixtures/ipc-wire-types/sdk-schema.json"))
    }

    private static func real() throws -> TypeEmitter {
        try TypeEmitter(sdkSchema: repositoryFile("cmux-tui/spec/sdk-schema.json"))
    }

    private static func expectGolden(_ emitter: TypeEmitter, _ name: String, _ golden: String) throws {
        let actual = try emitter.declaration(named: name)
        #expect(actual == golden + "\n", "\(name) differs from its golden; the emitter now writes:\n\(actual)")
    }

    // Golden shapes ---------------------------------------------------------

    /// Required, nullable, defaulted (also nullable with a non-null default),
    /// keyword, aliased and literal members; typed ids; a doc comment.
    @Test func anObjectHasExplicitKeysAndHonorsPresence() throws {
        try Self.expectGolden(Self.fixture(), "Tab", TypeEmitterGolden.tab)
    }

    /// An enum only requests use stays closed; its `default` case is escaped.
    @Test func anEnumTheAppOnlySendsIsClosed() throws {
        try Self.expectGolden(Self.fixture(), "SendMode", TypeEmitterGolden.sendMode)
    }

    /// An enum a result reaches keeps unknown values; its value "unknown" is one of them.
    @Test func anEnumTheAppDecodesIsExtensible() throws {
        try Self.expectGolden(Self.fixture(), "TabState", TypeEmitterGolden.tabState)
        let fallback = try Self.fixture().declaration(named: "DeviceKind")
        #expect(fallback.contains("        default: self = .unknown\n") && !fallback.contains("case unknown(String)"))
    }

    /// A recursive tagged union is `indirect`; its variants check their tag.
    @Test func aTaggedUnionHasAVariantStructPerTag() throws {
        try Self.expectGolden(Self.fixture(), "Node", TypeEmitterGolden.node)
    }

    @Test func anUntaggedUnionTriesItsVariantsInOrder() throws {
        try Self.expectGolden(Self.fixture(), "Entry", TypeEmitterGolden.entry)
    }

    /// Inline objects and enums nest; arrays and maps of named and typed-id values.
    @Test func inlineTypesNestInTheirMember() throws {
        let emitter = try Self.fixture()
        try Self.expectGolden(emitter, "Bundle", TypeEmitterGolden.bundle)
        #expect(try emitter.declaration(named: "Id") == "public typealias Id = UInt64\n")
        #expect(try emitter.declaration(named: "JsonValue") == "public typealias JsonValue = WireJSON\n")
    }

    // Files -----------------------------------------------------------------

    @Test func writesOneFilePerCommandFamilyAndOnlyMacOSTypes() throws {
        let files = try Self.fixture().files()
        #expect(files.map(\.fileName) == ["WireTypes+Support.swift", "WireTypes+Tabs.swift", "WireTypes+Unframed.swift"])
        #expect(files.map(\.fileName) == TypeEmitter.fileNames(commandFamilies: ["tabs"]))
        let tabs = files[1].text
        for name in ["Bundle", "DeadEntry", "DeviceKind", "Entry", "LiveEntry", "Node", "SendMode", "Tab", "TabState"] {
            #expect(tabs.contains("public struct \(name):") || tabs.contains("enum \(name):"), "\(name) missing")
        }
        #expect(!tabs.contains("CLIOnly"), "cli-dump has no macos client")
    }

    /// Two runs over the real schema write the same bytes, the files the plugin
    /// declares, with no key strategy and no force unwrap.
    @Test func theRealSchemaGivesTheSameFilesEveryRun() throws {
        let first = try Self.real().files()
        #expect(first == (try Self.real().files()))
        let families = try Self.real().schema.commandFamilies
        #expect(families.contains("terminal-io") && !families.contains("terminal-stream-events"))
        #expect(first.map(\.fileName) == TypeEmitter.fileNames(commandFamilies: families))
        let forceUnwrap = try NSRegularExpression(pattern: #"[\w\)\]]!(?!=)|try!|as!"#)
        for file in first {
            #expect(!file.text.contains("KeyEncodingStrategy") && !file.text.contains("KeyDecodingStrategy"))
            let range = NSRange(file.text.startIndex..., in: file.text)
            #expect(forceUnwrap.firstMatch(in: file.text, range: range) == nil, "\(file.fileName) force-unwraps")
        }
        let layout = try #require(first.first { $0.text.contains("public indirect enum Layout:") })
        #expect(layout.text.contains("    case unknownVariant(tag: String, json: WireJSON)\n"))
    }

    @Test func supportFileDeclaresTheTypedIDs() {
        let support = TypeEmitter.supportSource()
        for id in WireIDType.all {
            #expect(support.contains("public struct \(id.name): RawRepresentable"))
        }
        #expect(support.contains("public enum WireJSON: Codable, Sendable, Equatable"))
        #expect(WireIDType.forMember("panes", scalar: .uint64)?.name == "PaneID")
        #expect(WireIDType.forMember("panes", scalar: .string) == nil)
    }

    @Test func namesAreSwiftIdentifiers() {
        #expect(SwiftNames("terminal_id").member == "terminalID" && SwiftNames("utf-8").type == "Utf8")
        #expect(SwiftNames("session.ids").type == "SessionIDs" && SwiftNames("2d").member == "_2d")
        #expect(SwiftNames("default").escapedMember == "`default`" && SwiftNames("self").member == "selfValue")
    }

    // Refusals --------------------------------------------------------------

    private static func refused(types: String, result: String = #"{"kind": "ref", "name": "T"}"#) throws -> String {
        let document = try json(#"""
        {"families": {"tabs": {"id": 7}}, "types": \#(types), "commands": {"c": {"method_id": 1792,
          "request": {"kind": "object", "additional_properties": false, "fields": {}}, "result": \#(result)}}}
        """#)
        do {
            _ = try TypeEmitter(schema: TypeSchema(sdk: document)).files()
        } catch {
            return error.description
        }
        Issue.record("schema was not refused: \(types)")
        return ""
    }

    @Test func refusesWhatSwiftCannotExpress() throws {
        let field = #""presence": "optional", "nullable": true"#
        let cases: [(types: String, expected: String)] = [
            (#"{"T": {"kind": "enum", "values": [1, 2]}}"#, "$.types.T.values"),
            (#"{"T": {"kind": "enum", "values": ["a-b", "a_b"]}}"#, "both case aB"),
            (#"{"T": {"kind": "enum", "values": ["a"], "fallback": "b"}}"#, "$.types.T.fallback"),
            (#"{"T": {"kind": "object", "additional_properties": false, "fields": {"t": {"type": {"kind": "ref", "name": "T"}, "presence": "required", "nullable": false}}}}"#,
             "holds itself"),
            (#"{"T": {"kind": "tagged_union", "tag": "k", "variants": {"a": {"kind": "object", "additional_properties": false, "fields": {}}}}}"#,
             "literal \"a\""),
            (#"{"T": {"kind": "object", "additional_properties": false, "fields": {"m": {"type": {"kind": "scalar", "name": "boolean"}, \#(field), "default": true, "omit_nil": true}}}}"#,
             "$.types.T.fields.m.omit_nil"),
            (#"{"T": {"kind": "object", "additional_properties": false, "fields": {"m": {"type": {"kind": "scalar", "name": "int8"}, \#(field)}}}}"#,
             "$.types.T.fields.m.type.name"),
            (#"{"T": {"kind": "object", "additional_properties": false, "fields": {"m": {"type": {"kind": "ref", "name": "U"}, \#(field)}}}}"#,
             "undeclared type U"),
            (#"{"T": {"kind": "object", "additional_properties": false, "fields": {"a_b": {"type": {"kind": "scalar", "name": "string"}, \#(field)}, "a-b": {"type": {"kind": "scalar", "name": "string"}, \#(field)}}}}"#,
             "also another member's"),
            (#"{"String": {"kind": "object", "additional_properties": false, "fields": {}}, "T": {"kind": "ref", "name": "String"}}"#,
             "collides"),
        ]
        for (types, expected) in cases {
            let message = try Self.refused(types: types)
            #expect(message.hasPrefix("sdk-schema.json: $"), "\(message)")
            #expect(message.contains(expected), "\(types): \(message)")
        }
    }
}
