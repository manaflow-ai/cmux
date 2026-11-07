import Foundation
import Testing

@testable import CmuxAgentChat

/// `init?(jsonLine:)` must read every line the way the `Decodable` path does.
@Suite("TranscriptJSONValue parity")
struct TranscriptJSONValueParityTests {
    private func decoded(_ line: String) -> TranscriptJSONValue? {
        try? JSONDecoder().decode(TranscriptJSONValue.self, from: Data(line.utf8))
    }

    @Test(
        "the line parser matches the Decodable path",
        arguments: [
            #"null"#, #"true"#, #"false"#, #"0"#, #"1"#, #"-1"#, #"1.5"#, #"1.0"#, #"1e3"#, #"-0"#,
            #"9007199254740993"#, #"9223372036854775807"#, #"-9223372036854775808"#,
            #"9223372036854775808"#, #"18446744073709551616"#, #"1e30"#,
            #""""#, #""text""#, #""é\u00e9\n\"\\""#, #""\ud83d\ude00""#, #""\ud83d""#, #""\ude00x""#, "\"\u{1F600}\"",
            #"{}"#, #"[]"#, #"[1,"a",null,true,{"k":[2.5]}]"#,
            #"{"a":1,"a":2}"#, #"{"bool":true,"one":1,"zero":0,"float":0.25}"#,
            #"{"type":"response_item","payload":{"type":"message","content":[{"text":"hi"}]}}"#,
            #" {"spaced" : [ 1 , 2 ] } "#,
            "", "{", "[1,", "{\"a\":}", "tru", "01", "'a'", "[1,]", "{\"a\":1,}", "\u{1}",
        ]
    )
    func parity(line: String) {
        #expect(TranscriptJSONValue(jsonLine: line) == decoded(line), "line: \(line)")
    }

    @Test("booleans and the integers zero and one stay distinct")
    func booleansAreNotNumbers() {
        #expect(TranscriptJSONValue(jsonLine: "true") == .bool(true))
        #expect(TranscriptJSONValue(jsonLine: "1") == .integer(1))
        #expect(TranscriptJSONValue(jsonLine: "0") == .integer(0))
    }

    @Test("an integer past Int's range reads as a number without trapping")
    func integerPastIntRange() {
        #expect(TranscriptJSONValue(jsonLine: "9223372036854775808")?.int == nil)
        #expect(TranscriptJSONValue(jsonLine: "1e30")?.int == nil)
    }
}
