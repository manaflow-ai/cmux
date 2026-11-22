import Foundation
@testable import CmuxNextSettings
import Testing

/// A cmux-next.json (or theme file) that does not parse is told as where and what, never as the
/// error's dump (Leo, 2026-11-20: "bad toast of unreadable json").
struct JSONCProblemTests {
    private func problem(_ source: String) -> String {
        do {
            _ = try JSONC.parse(source)
            return "parsed"
        } catch {
            return JSONC.problem(error, in: source)
        }
    }

    @Test func aSyntaxErrorNamesItsLineAndNoErrorDump() {
        let text = problem("{\n  \"appearance\": {\n    \"accent\": blue\n  }\n}\n")
        #expect(text.contains("line 3"))
        #expect(!text.contains("Error Domain"))
        #expect(!text.contains("NSCocoaErrorDomain"))
        #expect(!text.contains("UserInfo"))
        #expect(!text.contains("Code=3840"))
    }

    @Test func aCommentKeepsTheLineNumber() {
        let text = problem("// settings\n/* two\nlines */\n{ \"a\": , }\n")
        #expect(text.contains("line 4"))
        #expect(!text.contains("Error Domain"))
    }

    @Test func anOpenCommentOrStringSaysSo() {
        #expect(problem("{ /* never closed") == "a /* comment is never closed")
        #expect(problem("{ \"a\": \"never closed") == "a string is never closed")
    }

    @Test func theToastReadsAsASentence() {
        let notice = SettingsDiagnosticNotices.Notice(path: "", value: nil, message: problem("{ \"a\": 1,, }"))
        let toast = SettingsDiagnosticStrings.message(notice, valueLimit: 80)
        #expect(toast.hasPrefix("cmux-next.json could not be read ("))
        #expect(!toast.contains("Error Domain"))
        #expect(toast.contains("line 1"))
    }

    @Test func positionsCountCharactersNotBytes() {
        #expect(JSONC.position(of: 0, in: "{}") == "line 1, column 1")
        #expect(JSONC.position(of: 4, in: "{\n  x") == "line 2, column 3")
        // "é" is two UTF-8 bytes and one column.
        #expect(JSONC.position(of: 3, in: "\"é\"") == "line 1, column 3")
    }

    @Test func aReadFailureIsItsPlainDescription() {
        let error = CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: "/tmp/cmux-next.json"])
        let text = JSONC.problem(error, in: nil)
        #expect(!text.contains("Error Domain"))
        #expect(!text.isEmpty)
    }
}
