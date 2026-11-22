import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Workstream tool JSON limiter")
struct WorkstreamToolJSONLimiterTests {
    private let limiter = WorkstreamToolJSONLimiter(scalarLimit: 8_000)

    private func sortedJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func decodedObject(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // `content` sorts before `file_path`, so cutting the serialized string
    // dropped the path and left text that does not parse.
    @Test func longWriteKeepsFilePathAndParses() throws {
        let content = String(repeating: "line of text\n", count: 1_600)
        let shortened = try #require(limiter.shortened(try sortedJSON([
            "content": content,
            "file_path": "/tmp/project/notes.md",
        ])))

        #expect(shortened.count <= 8_000)
        let object = try decodedObject(shortened)
        #expect(object["file_path"] as? String == "/tmp/project/notes.md")
        let listedContent = try #require(object["content"] as? String)
        #expect(listedContent.hasSuffix("..."))
        #expect(content.hasPrefix(String(listedContent.dropLast(3))))
        #expect(listedContent.count > 3_000)
    }

    @Test func everyLongValueGetsTheSameLength() throws {
        let shortened = try #require(limiter.shortened(try sortedJSON([
            "file_path": "/tmp/project/main.swift",
            "new_string": String(repeating: "n", count: 9_000),
            "old_string": String(repeating: "o", count: 9_000),
            "replace_all": true,
        ])))

        #expect(shortened.count <= 8_000)
        let object = try decodedObject(shortened)
        #expect(object["file_path"] as? String == "/tmp/project/main.swift")
        #expect(object["replace_all"] as? Bool == true)
        let newString = try #require(object["new_string"] as? String)
        let oldString = try #require(object["old_string"] as? String)
        #expect(newString.hasSuffix("...") && newString.hasPrefix("nnn"))
        #expect(oldString.hasSuffix("...") && oldString.hasPrefix("ooo"))
        #expect(newString.count == oldString.count)
    }

    @Test func nestedLongValuesAreShortenedInPlace() throws {
        let shortened = try #require(limiter.shortened(try sortedJSON([
            "edits": [
                ["new_string": String(repeating: "a", count: 7_000), "old_string": "before"],
                ["new_string": String(repeating: "b", count: 7_000), "old_string": "after"],
            ],
            "file_path": "/tmp/project/multi.swift",
        ])))

        #expect(shortened.count <= 8_000)
        let object = try decodedObject(shortened)
        #expect(object["file_path"] as? String == "/tmp/project/multi.swift")
        let edits = try #require(object["edits"] as? [[String: Any]])
        #expect(edits.map { $0["old_string"] as? String } == ["before", "after"])
        #expect(edits.allSatisfy { ($0["new_string"] as? String)?.hasSuffix("...") == true })
    }

    @Test func topLevelArrayIsShortenedInPlace() throws {
        let json = #"["# + String(repeating: #""keep","#, count: 3) + #"""#
            + String(repeating: "y", count: 9_000) + #""]"#
        let shortened = try #require(limiter.shortened(json))

        let array = try #require(try JSONSerialization.jsonObject(with: Data(shortened.utf8)) as? [String])
        #expect(array.prefix(3) == ["keep", "keep", "keep"])
        #expect(array.last?.hasSuffix("...") == true)
    }

    @Test func textOutsideTheShortenedValueIsKeptAsStored() throws {
        let json = #"{"content":""# + String(repeating: "x", count: 9_000)
            + #"","file_path":"\/tmp\/a.txt", "ratio":0.1,"count":1.0,"flag":true,"none":null}"#
        let shortened = try #require(limiter.shortened(json))

        #expect(shortened.count == 8_000)
        #expect(shortened.hasSuffix(#"...","file_path":"\/tmp\/a.txt", "ratio":0.1,"count":1.0,"flag":true,"none":null}"#))
    }

    @Test func veryLargeValueIsShortened() throws {
        let shortened = try #require(limiter.shortened(try sortedJSON([
            "content": String(repeating: "x", count: 1_048_576),
            "file_path": "/tmp/project/huge.bin",
        ])))

        #expect(shortened.count == 8_000)
        #expect(try decodedObject(shortened)["file_path"] as? String == "/tmp/project/huge.bin")
    }

    // A value the cut would not make shorter is never replaced, so many
    // short values cannot push the text over the limit on their own.
    @Test(arguments: [("a", 1_400), ("éé", 1_400), ("😀", 1_400), ("中中中", 1_000)])
    func manyShortValuesStayWhileTheLongOneIsShortened(short: String, count: Int) throws {
        let shortened = try #require(limiter.shortened(try sortedJSON([
            "ids": Array(repeating: short, count: count),
            "z": String(repeating: "x", count: 9_000),
        ])))

        #expect(shortened.count <= 8_000)
        let object = try decodedObject(shortened)
        #expect(object["ids"] as? [String] == Array(repeating: short, count: count))
        #expect((object["z"] as? String)?.hasSuffix("...") == true)
    }

    // Non-ASCII text keeps as many characters as ASCII text does.
    @Test func nonASCIIValueKeepsTheSameBudget() throws {
        let shortened = try #require(limiter.shortened(
            #"{"content":""# + String(repeating: "中", count: 9_000) + #""}"#
        ))

        #expect(shortened.count == 8_000)
        #expect((try decodedObject(shortened)["content"] as? String)?.hasSuffix("中...") == true)
    }

    // The limit counts Unicode scalars, not characters: each "e" plus
    // combining accent is one character and two scalars.
    @Test func combiningMarksCountAsScalars() throws {
        let content = String(repeating: "e\u{0301}", count: 5_000)
        let shortened = try #require(limiter.shortened(
            #"{"content":""# + content + #"","file_path":"/tmp/project/notes.md"}"#
        ))

        #expect(shortened.unicodeScalars.count <= 8_000)
        #expect(shortened.unicodeScalars.count > 7_900)
        let object = try decodedObject(shortened)
        #expect(object["file_path"] as? String == "/tmp/project/notes.md")
        let listedContent = try #require(object["content"] as? String)
        #expect(listedContent.hasSuffix("..."))
        #expect(content.unicodeScalars.starts(with: listedContent.unicodeScalars.dropLast(3)))
    }

    @Test func rawAndEscapedUnicodeAreNotSplit() throws {
        let json = #"{"content":""# + String(repeating: "é😀", count: 3_000)
            + #"","escaped":""# + String(repeating: #"\ud83d\ude00\u00e9"#, count: 2_000)
            + #"","file_path":"\/tmp\/project\/caf\u00e9.txt"}"#
        let shortened = try #require(limiter.shortened(json))

        #expect(shortened.count <= 8_000)
        let object = try decodedObject(shortened)
        #expect(object["file_path"] as? String == "/tmp/project/café.txt")
        let content = try #require(object["content"] as? String)
        #expect(content.count > 3)
        #expect(String(repeating: "é😀", count: 3_000).hasPrefix(String(content.dropLast(3))))
        let escaped = try #require(object["escaped"] as? String)
        #expect(escaped.count > 3)
        #expect(String(repeating: "😀é", count: 2_000).hasPrefix(String(escaped.dropLast(3))))
    }

    // The cut must land on a whole element whatever its offset in the value.
    @Test(arguments: 0..<12)
    func escapesAreNotSplitAtAnyOffset(padding: Int) throws {
        let element = #"\ud83d\ude00\\\n\"\u00e9é"#
        let decodedElement = "😀\\\n\"éé"
        let pad = String(repeating: "p", count: padding)
        let json = #"{"content":""# + pad + String(repeating: element, count: 1_200)
            + #"","file_path":"/tmp/project/offsets.txt"}"#
        let shortened = try #require(limiter.shortened(json))

        #expect(shortened.count <= 8_000)
        let object = try decodedObject(shortened)
        #expect(object["file_path"] as? String == "/tmp/project/offsets.txt")
        let content = try #require(object["content"] as? String)
        #expect(content.count > 1_000)
        #expect((pad + String(repeating: decodedElement, count: 1_200)).hasPrefix(String(content.dropLast(3))))
    }

    // An escaped backslash followed by "u" is not a unicode escape.
    @Test(arguments: 0..<8)
    func escapedBackslashBeforeUIsNotTreatedAsAnEscape(padding: Int) throws {
        let pad = String(repeating: "p", count: padding)
        let json = #"{"content":""# + pad + String(repeating: #"\\u00e9"#, count: 2_000) + #""}"#
        let shortened = try #require(limiter.shortened(json))

        let content = try #require(try decodedObject(shortened)["content"] as? String)
        #expect((pad + String(repeating: #"\u00e9"#, count: 2_000)).hasPrefix(String(content.dropLast(3))))
        #expect(shortened.count > 7_980)
    }

    @Test func textThatAlreadyFitsIsLeftToTheCaller() {
        #expect(limiter.shortened(#"{"file_path": "/tmp/a.txt", "content": "hi"}"#) == nil)
        #expect(limiter.shortened(#"{"c":""# + String(repeating: "中", count: 7_990) + #""}"#) == nil)
    }

    @Test func textThatIsNotAContainerIsLeftToTheCaller() {
        #expect(limiter.shortened(String(repeating: "x", count: 12_000)) == nil)
        #expect(limiter.shortened("\"" + String(repeating: "x", count: 12_000) + "\"") == nil)
    }

    @Test func unbalancedTextIsLeftToTheCaller() {
        #expect(limiter.shortened(#"{"content":""# + String(repeating: "x", count: 9_000)) == nil)
        #expect(limiter.shortened(#"{"content":""# + String(repeating: "x", count: 9_000) + #""}}"#) == nil)
        #expect(limiter.shortened(#"{"content":""# + String(repeating: "x", count: 9_000) + #"\"#) == nil)
    }

    @Test func structureAloneOverTheLimitIsLeftToTheCaller() throws {
        var object: [String: Any] = [:]
        for index in 0..<1_000 {
            object["key_number_\(index)"] = index
        }
        let json = try sortedJSON(object)
        try #require(json.count > 8_000)

        #expect(limiter.shortened(json) == nil)
    }
}
