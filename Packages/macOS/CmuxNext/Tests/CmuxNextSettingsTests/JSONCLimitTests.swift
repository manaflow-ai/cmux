@testable import CmuxNextSettings
import Foundation
import Testing

/// cmux-next.json's reader and writer agree: nesting deeper than ``JSONC/maxDepth`` (Chromium's
/// `kAbsoluteMaxDepth`, base/json/json_common.h) is refused on read and never written, and of members with equal
/// keys (U+00E9 and U+0065 U+0301 too) the last in the document is the one that reads and the one an edit changes
/// (base/json/json_parser.cc). The seeded fuzz of the same layer is ``SettingsFuzzTests``.
struct JSONCLimitTests {
    /// `depth` objects deep: `{"a":{"a":...{}}}`.
    static func objects(_ depth: Int) -> String {
        String(repeating: #"{"a":"#, count: depth - 1) + "{}" + String(repeating: "}", count: depth - 1)
    }

    /// A root object holding `depth - 1` arrays.
    static func arrays(_ depth: Int) -> String {
        #"{"a":"# + String(repeating: "[", count: depth - 1) + "0" + String(repeating: "]", count: depth - 1) + "}"
    }

    /// `value` wrapped in `depth` objects.
    static func nested(_ depth: Int, _ value: JSONValue = .bool(true)) -> JSONValue {
        (0..<depth).reduce(value) { inner, _ in .object(["a": inner]) }
    }

    /// A settings file in a fresh folder, holding `text`.
    static func file(_ text: String) throws -> (CmuxConfigFile, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-jsonc-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(text.utf8).write(to: url)
        return (CmuxConfigFile(url: url), url)
    }

    // MARK: - Depth on read

    @Test(arguments: [1, 2, JSONC.maxDepth - 1, JSONC.maxDepth, JSONC.maxDepth + 1, 512, 100_000])
    func nestingDeeperThanTheLimitIsRefused(depth: Int) async throws {
        let fits = depth <= JSONC.maxDepth
        for text in [Self.objects(depth), Self.arrays(depth)] {
            do {
                let parsed = try JSONC.parse(text)
                #expect(fits, "depth \(depth) parsed")
                _ = CmuxConfigSnapshot.parse(parsed, validDensities: [], validMetrics: [])
            } catch JSONC.Failure.tooDeep {
                #expect(!fits, "depth \(depth) was refused")
            }
        }
        let (file, url) = try Self.file(Self.objects(depth))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        if fits {
            try await file.set(.bool(true), at: ["fuzz"])
            #expect(try JSONC.parse(CmuxConfigFile.source(at: url))["fuzz"] == .bool(true))
        } else {
            await #expect(throws: CmuxConfigFile.Failure.self) { try await file.set(.bool(true), at: ["fuzz"]) }
            #expect(try CmuxConfigFile.source(at: url) == Self.objects(depth), "a refused file was rewritten")
        }
    }

    /// Braces in strings and comments are not nesting.
    @Test func bracesInStringsAndCommentsDoNotCount() throws {
        let deep = String(repeating: "{[", count: JSONC.maxDepth)
        let text = "{\"a\": \"\(deep)\", // \(deep)\n \"b\": /* \(deep) */ 1}"
        #expect(try JSONC.parse(text) == ["a": .string(deep), "b": 1])
    }

    // MARK: - Depth on write

    /// An edit that would nest past the limit throws and writes nothing; the file still reads and still edits.
    @Test(arguments: ["", "{}\n", "// mine\n{\n  \"keep\": 1\n}\n"])
    func anEditPastTheLimitIsRefusedAndTheFileStaysReadable(start: String) async throws {
        let (file, url) = try Self.file(start)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let longPath = Array(repeating: "a", count: JSONC.maxDepth + 1)
        let deepValue = Self.nested(JSONC.maxDepth)
        await #expect(throws: JSONC.Failure.self) { try await file.set(.bool(true), at: longPath) }
        await #expect(throws: JSONC.Failure.self) { try await file.set(deepValue, at: ["v"]) }
        await #expect(throws: JSONC.Failure.self) { try await file.apply([(path: ["ok"], value: .bool(true)), (path: ["v"], value: deepValue)]) }
        #expect(try CmuxConfigFile.source(at: url) == start, "a refused edit was written")
        #expect(throws: JSONC.Failure.self) { try JSONC.setting(.bool(true), at: longPath, in: start) }

        // At the limit an edit still writes, and the file reads back and takes the next edit.
        try await file.set(.bool(true), at: Array(longPath.dropFirst()))
        try await file.set(Self.nested(JSONC.maxDepth - 1), at: ["v"])
        let written = try JSONC.parse(CmuxConfigFile.source(at: url))
        #expect(written["v"] == Self.nested(JSONC.maxDepth - 1))
        try await file.remove(["a"])
        try await file.remove(["v"])
        #expect(try JSONC.parse(CmuxConfigFile.source(at: url))["a"] == nil)
    }

    // MARK: - Equal keys

    /// Keys that are distinct to Foundation but equal Swift strings (NFC and NFD) read as one member: the last.
    @Test func canonicallyEqualKeysReadAsTheLastMember() throws {
        let parsed = try JSONC.parse(#"{"é": 1, "é": 2, "shortcuts": {"é": "cmd+a", "é": "cmd+b"}}"#)
        #expect(parsed.objectValue?.count == 2)
        #expect(parsed["\u{E9}"] == 2)
        #expect(parsed["shortcuts"] == ["\u{E9}": "cmd+b"])
        _ = CmuxConfigSnapshot.parse(parsed, validDensities: [], validMetrics: [])
    }

    /// Exact duplicates too, at any level, inside arrays as well; a shadowed member's own members go with it.
    @Test func theLastOfDuplicateKeysWins() throws {
        let text = """
        {
          "a": {"x": 1, "y": 2}, // first
          "list": [{"k": 1, "k": 2}, {"k": 3}],
          "a": {"x": 3,},
        }
        """
        #expect(try JSONC.parse(text) == ["a": ["x": 3], "list": [["k": 2], ["k": 3]]])
    }

    /// An edit changes the member that reads, and a removal takes every member with that key.
    @Test func editsTargetTheMemberThatReads() throws {
        let text = #"{"é": 1, "é": 2}"#
        let edited = try JSONC.setting(.number(5), at: ["\u{E9}"], in: text)
        #expect(try JSONC.parse(edited)["\u{E9}"] == 5, "the edit changed a member that does not read:\n\(edited)")
        #expect(edited.hasPrefix(#"{"é": 1"#), "the shadowed member was edited:\n\(edited)")
        let removed = try JSONC.removing(["\u{E9}"], in: edited)
        #expect(try JSONC.parse(removed) == .object([:]), "a removal left a shadowed member in effect:\n\(removed)")
        #expect(JSONC.position(of: ["\u{E9}"], in: text)?.column == 16)
    }

    /// A key the reader does not take is malformed to the editor too, so no edit matches it as another key.
    @Test func aKeyWithABadEscapeIsMalformed() {
        let text = #"{"\x": 1, "": 2}"#
        #expect(throws: (any Error).self) { try JSONC.parse(text) }
        #expect(throws: JSONC.Failure.self) { try JSONC.setting(.bool(true), at: [""], in: text) }
    }
}
