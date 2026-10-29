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

private let fixturePath = "cmux-tui/spec/fixtures/ipc-wire-types/sdk-schema.json"
private let realPath = "cmux-tui/spec/sdk-schema.json"

/// TypeEmitter: the Swift wire types the `clients: macos`
/// commands reach, read from cmux-tui/spec/fixtures/ipc-wire-types and from
/// the real cmux-tui/spec/sdk-schema.json. Six shapes are compared with their
/// golden text (TypeEmitterGolden); the behavior of the real output is
/// CmuxNextIPCTests' WireTypesTests.
@Suite struct TypeEmitterTests {
    private static func fixture() throws -> TypeEmitter {
        try TypeEmitter(sdkSchema: repositoryFile(fixturePath))
    }

    private static func real() throws -> TypeEmitter {
        try TypeEmitter(sdkSchema: repositoryFile(realPath))
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

    /// A newer daemon writes events too: an enum a request and an event reach
    /// keeps unknown values, though no command result reaches it.
    @Test func anEnumAnEventReachesIsExtensible() throws {
        let emitter = try Self.fixture()
        #expect(emitter.decoded.contains("FlashStyle"))
        let flash = try emitter.declaration(named: "FlashStyle")
        #expect(flash.hasPrefix("public enum WireFlashStyle: RawRepresentable,") && flash.contains("case unknown(String)"))
    }

    /// A recursive tagged union is `indirect`; its variants check their tag.
    @Test func aTaggedUnionHasAVariantStructPerTag() throws {
        try Self.expectGolden(Self.fixture(), "Node", TypeEmitterGolden.node)
    }

    /// Only a variant whose required and literal members match is tried, and
    /// its error is kept: a matching value that does not decode fails.
    @Test func anUntaggedUnionTriesItsCandidateVariantsInOrder() throws {
        try Self.expectGolden(Self.fixture(), "Entry", TypeEmitterGolden.entry)
    }

    /// Inline objects and enums nest; arrays and maps of named and typed-id values.
    @Test func inlineTypesNestInTheirMember() throws {
        let emitter = try Self.fixture()
        try Self.expectGolden(emitter, "Bundle", TypeEmitterGolden.bundle)
        #expect(try emitter.declaration(named: "Id") == "public typealias WireId = UInt64\n")
        #expect(try emitter.declaration(named: "JsonValue") == "public typealias WireJsonValue = WireJSON\n")
    }

    // Files -----------------------------------------------------------------

    @Test func writesOneFilePerTypeTheCommandsReach() throws {
        let files = try Self.fixture().files()
        let types = ["Bundle", "ColorHex", "DeadEntry", "DeviceKind", "Entry", "FlashStyle", "Id", "JsonValue", "LiveEntry",
                     "Node", "SendMode", "Tab", "TabState"]
        #expect(files.map(\.fileName) == WireTypeFiles.supportFileNames + types.map { "WireTypes+\($0).swift" })
        for file in files.dropFirst(WireTypeFiles.supportFileNames.count) {
            let name = String(file.fileName.dropFirst("WireTypes+".count).dropLast(".swift".count))
            #expect(file.text.contains(" Wire\(name)"), "\(file.fileName) does not declare Wire\(name)")
        }
        // cli-dump has no macos client; FlashOrigin only an event reaches (task 022 writes event payloads).
        #expect(!files.contains { $0.text.contains("CLIOnly") || $0.text.contains("FlashOrigin") })
    }

    /// CmuxNextWireGenPlugin declares its outputs with WireTypeFiles(sdkSchema:),
    /// the same source file compiled into the plugin; the tool writes exactly them.
    @Test func thePluginDeclaresTheFilesTheToolWrites() throws {
        for path in [fixturePath, realPath] {
            let declared = try WireTypeFiles(sdkSchema: repositoryFile(path)).fileNames
            let written = try TypeEmitter(sdkSchema: repositoryFile(path)).files().map(\.fileName)
            #expect(declared == written, "\(path)")
        }
    }

    /// Two runs over the real schema write the same bytes, with no key
    /// strategy, no force unwrap and every file under the god-file cap
    /// (scripts/cmux-next/check-no-godfiles.sh: 400 lines, 3 top-level types).
    @Test func theRealSchemaGivesTheSameFilesEveryRunUnderTheCap() throws {
        let first = try Self.real().files()
        #expect(first == (try Self.real().files()))
        let forceUnwrap = try NSRegularExpression(pattern: #"[\w\)\]]!(?!=)|try!|as!"#)
        let topLevelType = try NSRegularExpression(
            pattern: #"^(public |internal |package |fileprivate |private |final |indirect )*(class|struct|enum|actor|protocol) "#,
            options: .anchorsMatchLines
        )
        for file in first {
            let range = NSRange(file.text.startIndex..., in: file.text)
            #expect(!file.text.contains("KeyEncodingStrategy") && !file.text.contains("KeyDecodingStrategy"))
            #expect(forceUnwrap.firstMatch(in: file.text, range: range) == nil, "\(file.fileName) force-unwraps")
            let lines = file.text.filter { $0 == "\n" }.count
            let types = topLevelType.numberOfMatches(in: file.text, range: range)
            #expect(lines <= 400 && types <= 3, "\(file.fileName): \(lines) lines, \(types) top-level types")
        }
        let layout = try #require(first.first { $0.fileName == "WireTypes+Layout.swift" })
        #expect(layout.text.contains("public indirect enum WireLayout:"))
        #expect(layout.text.contains("    case unknownVariant(tag: String, json: WireJSON)\n"))
    }

    // Typed ids -------------------------------------------------------------

    @Test func supportFilesDeclareTheTypedIDs() {
        let support = TypeEmitter.supportSources()
        #expect(support.map(\.fileName) == WireTypeFiles.supportFileNames)
        let text = support.map(\.text).joined()
        #expect(text.contains("public struct WireHandle<Kind: WireHandleKind>"))
        #expect(text.contains("public struct WireStringID<Kind: WireStringIDKind>"))
        for id in WireIDType.all {
            let generic = id.storage == .handle ? "WireHandle<WireHandleKinds" : "WireStringID<WireStringIDKinds"
            #expect(text.contains("public typealias \(id.name) = \(generic).\(id.kind)>\n"))
        }
        #expect(text.contains("public enum WireJSON: Codable, Sendable, Equatable"))
    }

    /// A member's location names its id before its wire name does, and only for its own scalar.
    @Test func theIDMapReadsLocationsThenMemberNames() {
        #expect(WireIDType.location(ofMemberAt: "$.types.Layout.variants.stack.fields.expanded") == "Layout.stack.expanded")
        #expect(WireIDType.location(ofMemberAt: "$.commands.split.request.fields.pane") == "split.request.pane")
        #expect(WireIDType.forMember("id", at: "$.types.LivePane.fields.id", scalar: .uint64)?.name == "WirePaneID")
        #expect(WireIDType.forMember("id", at: "$.types.Screen.fields.id", scalar: .uint64)?.name == "WireScreenID")
        #expect(WireIDType.forMember("id", at: "$.types.Other.fields.id", scalar: .uint64) == nil)
        #expect(WireIDType.forMember("panes", at: "$.types.Other.fields.panes", scalar: .uint64)?.name == "WirePaneID")
        #expect(WireIDType.forMember("panes", at: "$.types.Other.fields.panes", scalar: .string) == nil)
        let locations = WireIDType.all.flatMap(\.locations)
        #expect(Set(locations).count == locations.count, "a location names two ids")
    }

    /// Every location of the id map is a member of the real schema and gets
    /// its typed id: an entity's own id is the type its references use.
    @Test func everyMappedLocationOfTheRealSchemaIsTyped() throws {
        let emitter = try Self.real()
        for id in WireIDType.all {
            for location in id.locations.sorted() {
                let parts = location.split(separator: ".").map(String.init)
                let declaration = try emitter.declaration(named: try #require(parts.first))
                let property = SwiftNames(try #require(parts.last)).escapedMember
                let typed = try NSRegularExpression(pattern: #"public var \#(property): \[?\#(id.name)\]?\??\n"#)
                let range = NSRange(declaration.startIndex..., in: declaration)
                #expect(typed.firstMatch(in: declaration, range: range) != nil, "\(location) is not \(id.name)")
            }
        }
        let screen = try emitter.declaration(named: "Screen")
        #expect(screen.contains("public var activePane: WirePaneID\n") && screen.contains("public var id: WireScreenID\n"))
    }

    @Test func namesAreSwiftIdentifiers() {
        #expect(SwiftNames("terminal_id").member == "terminalID" && SwiftNames("utf-8").type == "Utf8")
        #expect(SwiftNames("session.ids").type == "SessionIDs" && SwiftNames("2d").member == "_2d")
        #expect(SwiftNames("default").escapedMember == "`default`" && SwiftNames("self").member == "selfValue")
    }

    /// A tagged union's own `TagKey` is never a variant's struct name.
    @Test func aNestedTypeNeverTakesAGeneratedMembersName() throws {
        let document = try json(#"""
        {"types": {"T": {"kind": "tagged_union", "tag": "k", "variants": {"tag_key": {"kind": "object", "fields": {
          "k": {"type": {"kind": "literal", "value": "tag_key"}, "presence": "required", "nullable": false}}}}}},
         "commands": {"c": {"request": {"kind": "object", "fields": {}}, "result": {"kind": "ref", "name": "T"}}}}
        """#)
        let union = try TypeEmitter(schema: TypeSchema(sdk: document)).declaration(named: "T")
        #expect(union.contains("case tagKey(TagKeyValue)") && union.contains("public struct TagKeyValue:"))
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
        let object = #"{"kind": "object", "additional_properties": false, "fields": {}}"#
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
            (#"{"JSON": \#(object), "T": {"kind": "ref", "name": "JSON"}}"#, "WireJSON collides"),
            (#"{"Handle": \#(object), "T": {"kind": "ref", "name": "Handle"}}"#, "WireHandle collides"),
            (#"{"t": \#(object), "T": {"kind": "untagged_union", "variants": [{"kind": "ref", "name": "t"}, {"kind": "ref", "name": "t"}]}}"#,
             "differs from T only in case"),
            (#"{"T-1": \#(object), "T": {"kind": "ref", "name": "T-1"}}"#, "must be an ASCII identifier"),
        ]
        for (types, expected) in cases {
            let message = try Self.refused(types: types)
            #expect(message.hasPrefix("sdk-schema.json: $"), "\(message)")
            #expect(message.contains(expected), "\(types): \(message)")
        }
    }
}
