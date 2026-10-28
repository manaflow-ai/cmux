import Foundation
import Testing
@testable import CmuxNextWireGen

private func repositoryFile(_ path: String) throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appendingPathComponent(path))
}

private func schema(command: String, types: String = "{}") throws(HotSchemaError) -> HotSchema {
    let text = #"{"types": \#(types), "events": {}, "commands": {"hot": \#(command)}}"#
    return try HotSchema(sdkSchema: Data(text.utf8))
}

private func binaryCommand(request: String) -> String {
    #"{"method_id": 768, "payload": "binary", "layout_version": 3, "request": \#(request), "#
        + #""result": {"kind": "object", "fields": {}, "additional_properties": false}}"#
}

/// The reader and emitter behind the app's hot-message codec (p05-ipc-183): they read the layouts
/// the way cmux-ipc's build-support/hot_codec.rs does, refuse what a layout cannot bound with its
/// JSON path, and write the same source every run.
@Suite struct HotEmitterTests {
    /// Fields go in the byte order of their names, whatever order the file lists; literal members
    /// are JSON only; optional and nullable members get a tag.
    @Test func readsFieldsInNameByteOrder() throws {
        let request = #"{"kind": "object", "additional_properties": false, "fields": {"#
            + #""zeta": {"type": {"kind": "scalar", "name": "uint16"}, "presence": "required", "nullable": false}, "#
            + #""kind": {"type": {"kind": "literal", "value": "x"}, "presence": "required", "nullable": false}, "#
            + #""beta": {"type": {"kind": "scalar", "name": "boolean"}, "presence": "optional", "nullable": false}, "#
            + #""alpha": {"type": {"kind": "scalar", "name": "string"}, "presence": "required", "nullable": true, "max_bytes": 8}"#
            + "}}"
        let hot = try schema(command: binaryCommand(request: request))
        let body = try #require(hot.structs["HotRequest"])
        #expect(body.fields.map(\.wire) == ["alpha", "beta", "zeta"])
        #expect(body.fields.map(\.tagged) == [true, true, false])
        #expect(body.fields.map(\.writesNull) == [true, false, false])
        #expect(body.fields.first?.type == .string(maxBytes: 8))
        #expect(body.literals == [HotSchema.Literal(wire: "kind", value: "x")])
        #expect(hot.messages.map(\.type) == ["HotRequest", "HotResult"])
        #expect(hot.messages.map(\.layoutVersion) == [3, 3])
    }

    @Test func refusesWhatALayoutCannotBound() throws {
        let field = { (type: String) in
            #"{"kind": "object", "additional_properties": false, "fields": {"f": {"type": \#(type), "presence": "required", "nullable": false}}}"#
        }
        let node = #"{"Node": {"kind": "object", "additional_properties": false, "fields": {"next": "#
            + #"{"type": {"kind": "ref", "name": "Node"}, "presence": "optional", "nullable": true}}}}"#
        let cases: [(request: String, types: String, message: String)] = [
            (field(#"{"kind": "scalar", "name": "string"}"#), "{}", "needs max_bytes"),
            (field(#"{"kind": "array", "items": {"kind": "scalar", "name": "uint16"}}"#), "{}", "needs max_items"),
            (field(#"{"kind": "map", "values": {"kind": "scalar", "name": "uint16"}}"#), "{}", "has no binary layout"),
            (field(#"{"kind": "ref", "name": "Node"}"#), node, "recursive type"),
        ]
        for (request, types, message) in cases {
            do throws(HotSchemaError) {
                _ = try schema(command: binaryCommand(request: request), types: types)
                Issue.record("accepted: \(request)")
            } catch {
                #expect(error.path.hasPrefix("$.") && error.message.contains(message), "\(error)")
            }
        }
    }

    /// The real schema's hot set, each body a `Hot<Name>` the app's tests decode; two runs write the
    /// same bytes.
    @Test func emitsTheSchemaLayoutsDeterministically() throws {
        let sdk = try repositoryFile("cmux-tui/spec/sdk-schema.json")
        let emitter = try HotEmitter(sdkSchema: sdk)
        let names = emitter.schema.messages.map { "\($0.name) \($0.part.rawValue)" }
        #expect(names == [
            "resize-attached-view request", "resize-attached-view result",
            "scroll-surface request", "scroll-surface result",
            "set-client-sizing request", "set-client-sizing result",
            "snapshot-request request", "snapshot-request result",
            "scroll-changed event", "size-state event", "surface-resized event",
        ])
        let source = emitter.source()
        #expect(source == (try HotEmitter(sdkSchema: sdk)).source())
        #expect(source.contains("public struct HotSizeStateEvent: Hashable, Sendable {"))
        #expect(source.contains("extension HotLayout where Body == HotEmptyResult {"))
        #expect(source.contains("public static var scrollSurfaceResult: Self"))
        #expect(!source.contains("HotTitleChangedEvent"))
    }
}
