import CmuxNextSettings
import Foundation
import Testing

@Suite struct JSONCTests {
    let commented = """
    {
      // Appearance of the chrome.
      "appearance": {
        "density": "compact", /* trailing block */
      },
      "shortcuts": {
        "bindings": {
          "splitRight": "cmd+\\\\", // keep this note
        },
      },
      "unknownKey": [1, 2, 3,],
    }
    """

    @Test func parsesCommentsAndTrailingCommas() throws {
        let value = try JSONC.parse(commented)
        #expect(value.value(at: ["appearance", "density"]) == "compact")
        #expect(value.value(at: ["shortcuts", "bindings", "splitRight"]) == "cmd+\\")
        #expect(value["unknownKey"] == [1, 2, 3])
    }

    @Test func stringsKeepCommentMarkers() throws {
        let value = try JSONC.parse(#"{"url": "https://cmux.com/*not a comment*/", "x": "a // b"}"#)
        #expect(value["url"] == "https://cmux.com/*not a comment*/")
        #expect(value["x"] == "a // b")
    }

    @Test func emptyOrCommentOnlyDocumentIsEmptyObject() throws {
        #expect(try JSONC.parse("") == .object([:]))
        #expect(try JSONC.parse("// nothing yet\n") == .object([:]))
    }

    @Test func replacingAValueKeepsEverythingElse() throws {
        let edited = try JSONC.setting("comfortable", at: ["appearance", "density"], in: commented)
        #expect(edited == commented.replacingOccurrences(of: "\"density\": \"compact\"", with: "\"density\": \"comfortable\""))
    }

    @Test func insertingKeepsCommentsAndTrailingCommaStyle() throws {
        let edited = try JSONC.setting("cmd+shift+g", at: ["shortcuts", "bindings", "tabGroup.create"], in: commented)
        #expect(edited.contains("// keep this note"))
        #expect(edited.contains("// Appearance of the chrome."))
        #expect(edited.contains("\"tabGroup.create\": \"cmd+shift+g\","))
        let parsed = try JSONC.parse(edited)
        #expect(parsed.value(at: ["shortcuts", "bindings", "tabGroup.create"]) == "cmd+shift+g")
        #expect(parsed.value(at: ["shortcuts", "bindings", "splitRight"]) == "cmd+\\")
        #expect(parsed["unknownKey"] == [1, 2, 3])
    }

    @Test func insertingAfterLastMemberWithSameLineComment() throws {
        let source = "{\n  \"a\": 1 // note\n}\n"
        let edited = try JSONC.setting(2, at: ["b"], in: source)
        #expect(edited == "{\n  \"a\": 1, // note\n  \"b\": 2\n}\n")
    }

    @Test func insertingAfterTrailingCommaKeepsItsComment() throws {
        let source = "{\n  \"a\": 1, // keep\n}\n"
        #expect(try JSONC.setting(2, at: ["b"], in: source) == "{\n  \"a\": 1, // keep\n  \"b\": 2,\n}\n")
    }

    @Test func creatingNestedObjects() throws {
        let edited = try JSONC.setting(240, at: ["appearance", "metrics", "sidebarWidth"], in: "{\n  \"app\": {}\n}\n")
        let parsed = try JSONC.parse(edited)
        #expect(parsed.value(at: ["appearance", "metrics", "sidebarWidth"]) == 240)
        #expect(parsed["app"] == .object([:]))
        #expect(edited.contains("\n  \"appearance\": {\n    \"metrics\": {\n      \"sidebarWidth\": 240\n    }\n  }"))
    }

    @Test func settingIntoEmptyObjectAndEmptyFile() throws {
        #expect(try JSONC.parse(try JSONC.setting(true, at: ["x"], in: "{}")) == ["x": true])
        let fresh = try JSONC.setting("dark", at: ["app", "appearance"], in: "")
        #expect(fresh == "{\n  \"app\": {\n    \"appearance\": \"dark\"\n  }\n}\n")
    }

    @Test func replacingAScalarWithAnObjectPath() throws {
        let edited = try JSONC.setting(1, at: ["a", "b"], in: #"{"a": "x"}"#)
        #expect(try JSONC.parse(edited) == ["a": ["b": 1]])
    }

    @Test func removingMembers() throws {
        #expect(try JSONC.removing(["b"], in: #"{"a":1,"b":2,"c":3}"#) == #"{"a":1,"c":3}"#)
        #expect(try JSONC.removing(["c"], in: #"{"a":1,"b":2,"c":3}"#) == #"{"a":1,"b":2}"#)
        #expect(try JSONC.removing(["a"], in: #"{"a":1}"#) == #"{}"#)
        let multiline = "{\n  \"a\": 1,\n  // about b\n  \"b\": 2\n}\n"
        #expect(try JSONC.removing(["b"], in: multiline) == "{\n  \"a\": 1\n  // about b\n}\n")
        #expect(try JSONC.removing(["missing"], in: multiline) == multiline)
        let nested = try JSONC.removing(["shortcuts", "bindings", "splitRight"], in: commented)
        #expect(try JSONC.parse(nested).value(at: ["shortcuts", "bindings"]) == .object([:]))
    }

    @Test func rejectsNonObjectRoot() {
        #expect(throws: JSONC.Failure.rootIsNotObject) { try JSONC.setting(1, at: ["a"], in: "[1]") }
        // An empty key path used to trap in a precondition; it is refused.
        #expect(throws: JSONC.Failure.emptyPath) { try JSONC.setting(1, at: [], in: "{}") }
        #expect(throws: JSONC.Failure.emptyPath) { try JSONC.removing([], in: "{\"a\": 1}") }
    }

    @Test func keyPathsKeepActionIDsWhole() {
        #expect(CmuxConfigFile.keyPath(from: "appearance.metrics.sidebarWidth") == ["appearance", "metrics", "sidebarWidth"])
        #expect(CmuxConfigFile.keyPath(from: "shortcuts.bindings.tabGroup.create") == ["shortcuts", "bindings", "tabGroup.create"])
        #expect(CmuxConfigFile.keyPath(from: "shortcuts.tabGroup.create") == ["shortcuts", "tabGroup.create"])
        #expect(CmuxConfigFile.keyPath(from: "shortcuts.showModifierHoldHints") == ["shortcuts", "showModifierHoldHints"])
        #expect(CmuxConfigFile.keyPath(from: "shortcuts.when.splitRight") == ["shortcuts", "when", "splitRight"])
    }
}
