import Foundation
import Testing
@testable import CmuxSettings

@Suite("JSONCSanitizer")
struct JSONCSanitizerTests {
    @Test func matchesLegacyOutputForTrickyInputs() throws {
        let fixtures: [(source: String, expected: String)] = [
            (
                source: #"{"url":"https://example.com/a//b","pattern":"/* literal */","value":1// remove"# + "\n}",
                expected: #"{"url":"https://example.com/a//b","pattern":"/* literal */","value":1"# + "\n}"
            ),
            (
                source: #"{"text":"quote: \" // still a string","path":"C:\\tmp",// remove"# + "\n\"ok\":true,}",
                expected: #"{"text":"quote: \" // still a string","path":"C:\\tmp","# + "\n\"ok\":true}"
            ),
            (
                source: #"{"value":1}/* trailing block comment */"#,
                expected: #"{"value":1}"#
            ),
            (
                source: "{\r\n// remove\r\n\"value\": 1,\r\n}\r\n",
                expected: "{\r\n\r\n\"value\": 1\r\n}\r\n"
            ),
            (
                source: "{\"value\": /* remove\nthis block */ 1,}",
                expected: "{\"value\":  1}"
            ),
            (
                source: "{\"日本語\":\"値 // literal\",// 削除\r\n\"emoji\":\"🪁\",\u{00a0}}",
                expected: "{\"日本語\":\"値 // literal\",\r\n\"emoji\":\"🪁\"\u{00a0}}"
            ),
        ]

        for fixture in fixtures {
            let sanitized = try JSONCSanitizer().sanitize(Data(fixture.source.utf8))
            #expect(String(decoding: sanitized, as: UTF8.self) == fixture.expected)
        }
    }

    @Test func preservesSupportedEncodingDetection() throws {
        let source = "{\"value\": 1,}"
        let expected = Data("{\"value\": 1}".utf8)
        let utf16 = try #require(source.data(using: .utf16LittleEndian))
        let utf32 = try #require(source.data(using: .utf32BigEndian))
        let fixtures = [
            Data([0xEF, 0xBB, 0xBF]) + Data(source.utf8),
            Data([0xFF, 0xFE]) + utf16,
            Data([0x00, 0x00, 0xFE, 0xFF]) + utf32,
        ]

        for fixture in fixtures {
            #expect(try JSONCSanitizer().sanitize(fixture) == expected)
        }
    }

    @Test func rejectsUnterminatedBlockComment() {
        #expect(throws: JSONCSanitizer.Failure.self) {
            try JSONCSanitizer().sanitize(Data(#"{"value":1}/* unterminated"#.utf8))
        }
    }

    @Test func sanitizesRealistic150KBFixtureWithinOneSecond() throws {
        var source = "{\n  // generated cmux configuration\n  \"workspaces\": [\n"
        source.reserveCapacity(170_000)
        for index in 0..<520 {
            source += """
                // Workspace \(index)
                {
                  "id": \(index),
                  "name": "project-\(index) // literal",
                  "command": "printf \\"ready\\" && echo /* literal */",
                  "metadata": { /* generated metadata \(index) */
                    "path": "/tmp/project-\(index)",
                    "enabled": true,
                  },
                  "tags": ["swift", "jsonc",],
                },

            """
        }
        source += "  ],\n}\n"

        let data = Data(source.utf8)
        #expect((140_000...180_000).contains(data.count))

        let clock = ContinuousClock()
        let start = clock.now
        let sanitized = try JSONCSanitizer().sanitize(data)
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(1), "Sanitizing \(data.count) bytes took \(elapsed)")
        #expect(try JSONSerialization.jsonObject(with: sanitized) is [String: Any])
    }
}
