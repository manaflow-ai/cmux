import Foundation
import Testing
@testable import CmuxNextDaemon

/// `WireCoding` writes each key as the type's `CodingKeys` spell it: no
/// snake_case rewrite and no key sort (p05-ipc-046). The generated wire
/// types carry the schema's names, and serde reads objects by name.
struct WireCodingTests {
    private struct ProbeRequest: DaemonRequest {
        typealias Response = EmptyResponse
        static let command = "wire-coding-probe"

        var mutationID: String
        var paneIndex: Int
        var extra: JSONValue

        enum CodingKeys: String, CodingKey {
            case mutationID = "mutation_id", paneIndex = "pane_index", extra
        }
    }

    private struct VerbatimProbeRequest: DaemonRequest, VerbatimFieldsRequest {
        typealias Response = EmptyResponse
        static let command = "wire-coding-verbatim-probe"

        var appName: String
        var args: JSONValue

        enum CodingKeys: String, CodingKey {
            case appName = "app_name"
        }

        var verbatimFields: [String: JSONValue] { ["args": args] }
    }

    private static func fields(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func requestKeysAreTheCodingKeysUnchanged() throws {
        let request = ProbeRequest(mutationID: "m-1", paneIndex: 3, extra: .object(["camelKey": .bool(true)]))
        let line = try WireCoding.encodeRequest(request, id: 9)
        #expect(try Self.fields(line) == .object([
            "id": .number(9), "cmd": .string("wire-coding-probe"), "mutation_id": .string("m-1"), "pane_index": .number(3),
            "extra": .object(["camelKey": .bool(true)]),
        ]))
    }

    /// A camelCase key is not rewritten: before this change the encoder sent
    /// `camelKey` inside a nested object as `camel_key`.
    @Test func nestedObjectKeysStayAsWritten() throws {
        let line = try WireCoding.encoder().encode(JSONValue.object(["camelKey": .object(["innerKey": .null])]))
        #expect(String(decoding: line, as: UTF8.self).contains("\"camelKey\":{\"innerKey\":null}"))
    }

    @Test func verbatimFieldsGoOnTheWireUnchanged() throws {
        let args = JSONValue.object(["someArg": .array([.string("a/b")]), "other_arg": .number(1)])
        let line = try WireCoding.encodeRequest(VerbatimProbeRequest(appName: "notes", args: args), id: 2)
        #expect(try Self.fields(line) == .object([
            "id": .number(2), "cmd": .string("wire-coding-verbatim-probe"), "app_name": .string("notes"), "args": args,
        ]))
        #expect(String(decoding: line, as: UTF8.self).contains("\"a/b\""))
    }

    @Test func aRequestWithoutAnIDOmitsIt() throws {
        let line = try WireCoding.encodeRequest(ProbeRequest(mutationID: "m", paneIndex: 0, extra: .null), id: nil)
        #expect(try Self.fields(line)["id"] == nil)
        #expect(!line.contains(UInt8(ascii: "\n")))
    }
}
