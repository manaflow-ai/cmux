import Foundation
import Testing
@testable import CmuxNextDaemon

/// `WireCoding` writes each key as the type's `CodingKeys` spell it: no
/// snake_case rewrite and no key sort. The generated wire
/// types carry the schema's names, and serde reads objects by name.
struct WireCodingTests {
    private struct ProbeRequest: DaemonRequest {
        typealias Response = EmptyResponse
        static let commandName: DaemonCommandName = "wire-coding-probe"

        var mutationID: String
        var paneIndex: Int
        var extra: JSONValue

        enum CodingKeys: String, CodingKey {
            case mutationID = "mutation_id", paneIndex = "pane_index", extra
        }
    }

    private struct VerbatimProbeRequest: DaemonRequest, VerbatimFieldsRequest {
        typealias Response = EmptyResponse
        static let commandName: DaemonCommandName = "wire-coding-verbatim-probe"

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

    /// A CodingKey is not rewritten, in a nested struct too: the snake_case
    /// strategy sent this `{"outer_key":{"inner_key":true}}`.
    @Test func nestedCodingKeysStayAsWritten() throws {
        struct Inner: Encodable {
            var innerKey: Bool
        }
        struct Outer: Encodable {
            var outerKey: Inner
        }
        let line = try WireCoding.encoder().encode(Outer(outerKey: Inner(innerKey: true)))
        #expect(try Self.fields(line) == .object(["outerKey": .object(["innerKey": .bool(true)])]))
    }

    /// The hand-written requests spell their wire names in `CodingKeys`, nested
    /// types and flattened mutation fields included, so the lines the strategy
    /// wrote do not change.
    @Test func handWrittenRequestsKeepTheirSnakeCaseNames() throws {
        #expect(try Self.fields(WireCoding.encodeRequest(SubscribeRequest(), id: 1)) == .object([
            "id": .number(1), "cmd": .string("subscribe"), "tree_events": .string("deltas"),
        ]))

        let mount = AppsMountRequest(app: "notes", interface: "main", mountID: "m-1",
                                     context: .object(["camelKey": .bool(true)]))
        #expect(try Self.fields(WireCoding.encodeRequest(mount, id: 2)) == .object([
            "id": .number(2), "cmd": .string("apps-mount"), "app": .string("notes"), "interface": .string("main"),
            "mount_id": .string("m-1"), "context": .object(["camelKey": .bool(true)]),
        ]))

        let mutation = MutationIdentity(origin: "app", mutationID: "m-2", expectedGeneration: DaemonGeneration(rawValue: "g"),
                                        expectedRevision: 4)
        let close = CloseTabsRequest(surfaces: [SurfaceID(rawValue: 5)], endTerminals: true, mutation: mutation)
        #expect(try Self.fields(WireCoding.encodeRequest(close, id: 3)) == .object([
            "id": .number(3), "cmd": .string("close-tabs"), "surfaces": .array([.number(5)]), "end_terminals": .bool(true),
            "origin": .string("app"), "mutation_id": .string("m-2"), "expected_generation": .string("g"),
            "expected_revision": .number(4),
        ]))

        let clear = ClearHistoryRequest(surface: SurfaceID(rawValue: 6), fallbackKey: .command("k"))
        func modifiers(super pressed: Bool) -> JSONValue {
            .object([
                "shift": .bool(false), "control": .bool(false), "alt": .bool(false), "super": .bool(pressed),
                "caps_lock": .bool(false), "num_lock": .bool(false),
            ])
        }
        #expect(try Self.fields(WireCoding.encodeRequest(clear, id: 4)) == .object([
            "id": .number(4), "cmd": .string("clear-history"), "surface": .number(6),
            "fallback_key": .object([
                "key": .string("k"), "mods": modifiers(super: true), "consumed_mods": modifiers(super: false),
                "utf8": .string(""),
                "unshifted_codepoint": .string("k"), "action": .string("press"), "macos_option_as_alt": .bool(true),
            ]),
        ]))
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
