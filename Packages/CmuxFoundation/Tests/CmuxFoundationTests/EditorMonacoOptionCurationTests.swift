import Foundation
import Testing

@testable import CmuxFoundation

/// Behavioral coverage for ``EditorMonacoOptionCuration/curate(_:)``: the pure
/// mapping from a cmux.json `editor` object to the Monaco options subset
/// injected into the `cmux edit` webview. The curation is the security +
/// correctness boundary — only an allowlist of viewer/edit-safe options is
/// forwarded, with type and enum validation; dangerous model-level keys are
/// always dropped.
struct EditorMonacoOptionCurationTests {
    @Test func forwardsValidScalarOptions() {
        let out = EditorMonacoOptionCuration.curate([
            "wordWrap": "on",
            "tabSize": 2,
            "insertSpaces": false,
            "lineNumbers": "relative",
            "cursorStyle": "block",
            "letterSpacing": 1.5,
        ])
        #expect(out["wordWrap"] as? String == "on")
        #expect(out["tabSize"] as? Int == 2)
        #expect(out["insertSpaces"] as? Bool == false)
        #expect(out["lineNumbers"] as? String == "relative")
        #expect(out["cursorStyle"] as? String == "block")
        #expect(out["letterSpacing"] as? Double == 1.5)
    }

    @Test func dropsDangerousAndUnknownKeys() {
        let out = EditorMonacoOptionCuration.curate([
            "model": ["foo": "bar"],
            "value": "malicious",
            "language": "javascript",
            "theme": "evil",
            "readOnly": false,
            "automaticLayout": true,
            "domReadOnly": false,
            "totallyMadeUp": 42,
            "wordWrap": "off",
        ])
        #expect(out["model"] == nil)
        #expect(out["value"] == nil)
        #expect(out["language"] == nil)
        #expect(out["theme"] == nil)
        #expect(out["readOnly"] == nil)
        #expect(out["automaticLayout"] == nil)
        #expect(out["domReadOnly"] == nil)
        #expect(out["totallyMadeUp"] == nil)
        #expect(out["wordWrap"] as? String == "off")
    }

    @Test func rejectsOutOfEnumAndOutOfRangeValues() {
        let out = EditorMonacoOptionCuration.curate([
            "wordWrap": "diagonal",
            "lineNumbers": 5,
            "tabSize": 999,
            "cursorStyle": "spiral",
            "letterSpacing": 999,
        ])
        #expect(out["wordWrap"] == nil)
        #expect(out["lineNumbers"] == nil)
        #expect(out["tabSize"] == nil)
        #expect(out["cursorStyle"] == nil)
        #expect(out["letterSpacing"] == nil)
        #expect(out.isEmpty)
    }

    @Test func curatesNestedObjects() {
        let out = EditorMonacoOptionCuration.curate([
            "minimap": ["enabled": false, "side": "left", "bogus": "x"],
            "bracketPairColorization": ["enabled": true],
            "stickyScroll": ["enabled": true, "maxLineCount": 3],
            "guides": ["indentation": false, "bracketPairs": "active"],
        ])
        let minimap = out["minimap"] as? [String: Any]
        #expect(minimap?["enabled"] as? Bool == false)
        #expect(minimap?["side"] as? String == "left")
        #expect(minimap?["bogus"] == nil)
        #expect((out["bracketPairColorization"] as? [String: Any])?["enabled"] as? Bool == true)
        let sticky = out["stickyScroll"] as? [String: Any]
        #expect(sticky?["enabled"] as? Bool == true)
        #expect(sticky?["maxLineCount"] as? Int == 3)
        let guides = out["guides"] as? [String: Any]
        #expect(guides?["indentation"] as? Bool == false)
        #expect(guides?["bracketPairs"] as? String == "active")
    }

    @Test func curatesRulersArray() {
        let out = EditorMonacoOptionCuration.curate(["rulers": [80, 120, -3, 0, "x"]])
        #expect(out["rulers"] as? [Int] == [80, 120])
    }

    @Test func emptyConfigYieldsEmptyOptions() {
        #expect(EditorMonacoOptionCuration.curate([:]).isEmpty)
        #expect(EditorMonacoOptionCuration.curate(["onlyUnknown": true]).isEmpty)
    }
}
