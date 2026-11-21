import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// `JSONValue.decoded(as:)` decodes a parsed record as `JSONDecoder` decodes its JSON text: the
/// chat's records now decode straight from the parsed value (no second encode and parse of a
/// 2 MB tool output), so every shape the chat reads must come out the same.
struct JSONValueDecodingTests {
    static func both<T: Decodable & Equatable>(_ type: T.Type, _ json: String) throws -> (direct: T, text: T) {
        let data = Data(json.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return (try value.decoded(as: T.self), try JSONDecoder().decode(T.self, from: data))
    }

    @Test(arguments: [
        #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi **there**"},"messageId":"m1"}"#,
        #"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking"}}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"tc1","title":"run tests","kind":"execute","status":"in_progress","rawInput":{"command":"swift test","n":[1,2.5,null,true]}}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"tc1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"ok\nline 2"}},{"type":"diff","path":"a.swift","oldText":"x","newText":"y"},{"type":"content","content":{"type":"image","mimeType":"image/png","data":"iVBORw0KGgo="}}],"rawOutput":{"exit_code":0}}"#,
        #"{"sessionUpdate":"plan","entries":[{"content":"Read the file","priority":"high","status":"pending"}]}"#,
        #"{"sessionUpdate":"current_mode_update","currentModeId":"plan"}"#,
        #"{"sessionUpdate":"usage_update","used":1200,"size":200000}"#,
        #"{"sessionUpdate":"session_info_update","title":"Fix the relay"}"#,
        #"{"sessionUpdate":"session_info_update"}"#,
    ])
    func sessionUpdatesDecodeAsFromText(_ json: String) throws {
        let (direct, text) = try Self.both(ACPSessionUpdate.self, json)
        #expect(direct == text)
    }

    @Test func refusesWhatJSONDecoderRefuses() throws {
        let unknown = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"sessionUpdate":"something_new"}"#.utf8))
        #expect(throws: DecodingError.self) { try unknown.decoded(as: ACPSessionUpdate.self) }
        // No conversion between JSON types, and integers only from numbers they hold exactly.
        #expect(throws: DecodingError.self) { try JSONValue.number(1).decoded(as: String.self) }
        #expect(throws: DecodingError.self) { try JSONValue.string("1").decoded(as: Int.self) }
        #expect(throws: DecodingError.self) { try JSONValue.number(1.5).decoded(as: Int.self) }
        #expect(throws: DecodingError.self) { try JSONValue.number(300).decoded(as: UInt8.self) }
        #expect(throws: DecodingError.self) { try JSONValue.object([:]).decoded(as: [Int].self) }
    }

    struct Shapes: Codable, Equatable {
        var name: String
        var count: Int
        var ratio: Double
        var flag: Bool?
        var missing: String?
        var tags: [String]
        var nested: [String: [Int]]
        var blob: Data
        var link: URL
        var when: Date
        var raw: JSONValue
        var maybe: [Int?]
    }

    @Test func foundationShapesDecodeAsFromText() throws {
        let json = #"{"name":"a","count":3,"ratio":0.25,"flag":null,"tags":["x","y"],"nested":{"k":[1,2]},"blob":"AQID","link":"https://example.com/a?b=1","when":12.5,"raw":{"a":[1,{"b":null}]},"maybe":[1,null,3]}"#
        let (direct, text) = try Self.both(Shapes.self, json)
        #expect(direct == text)
        #expect(direct.blob == Data([1, 2, 3]))
        #expect(direct.flag == nil && direct.missing == nil)
    }

    /// `JSONValue(jsonData:)` (what the link parses replies with) gives the value
    /// `JSONDecoder` gives: booleans stay booleans (never 1 or 0), numbers stay numbers.
    @Test func serializationParseMatchesJSONDecoder() throws {
        let json = #"{"t":true,"f":false,"one":1,"zero":0,"half":1.5,"neg":-2,"big":9007199254740993,"n":null,"s":"caf\u00e9 \ud83d\ude00 \"q\"\n","a":[1,"x",[],{}],"o":{"deep":{"k":[true,null]}}}"#
        let data = Data(json.utf8)
        let parsed = try #require(JSONValue(jsonData: data))
        #expect(parsed == (try JSONDecoder().decode(JSONValue.self, from: data)))
        #expect(parsed["t"] == .bool(true) && parsed["one"] == .number(1))
        #expect(JSONValue(jsonData: Data("{".utf8)) == nil)
    }
}
