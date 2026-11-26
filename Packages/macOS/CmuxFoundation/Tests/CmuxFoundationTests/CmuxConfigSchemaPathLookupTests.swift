import Foundation
import Testing
@testable import CmuxFoundation

@Suite("cmux.json schema path lookup")
struct CmuxConfigSchemaPathLookupTests {
    private let lookup = CmuxConfigSchemaPathLookup()

    @Test("declares settings leaves, sections, and map entries")
    func declaresKnownPaths() {
        #expect(lookup.isDeclared(["terminal", "scrollSpeed"]))
        #expect(lookup.isDeclared(["fileEditor", "wordWrap"]))
        #expect(lookup.isDeclared(["terminal", "rendererRealization", "maxWarmRenderers"]))
        #expect(lookup.isDeclared(["sidebar"]))
        // A $ref-backed property.
        #expect(lookup.isDeclared(["paneBorderColor"]))
        // An entry of a keyed map.
        #expect(lookup.isDeclared(["shortcuts", "bindings", "toggleSidebar"]))
    }

    @Test("rejects paths the schema doesn't declare")
    func rejectsUnknownPaths() {
        #expect(!lookup.isDeclared([]))
        #expect(!lookup.isDeclared(["terminal", "scrollSpeeed"]))
        #expect(!lookup.isDeclared(["nope"]))
        #expect(!lookup.isDeclared(["terminal", "scrollSpeed", "child"]))
    }

    @Test("returns schema defaults")
    func returnsDefaults() {
        #expect((lookup.defaultValue(at: ["terminal", "scrollSpeed"]) as? NSNumber)?.doubleValue == 1.0)
        #expect((lookup.defaultValue(at: ["fileEditor", "wordWrap"]) as? NSNumber)?.boolValue == false)
        #expect(lookup.defaultValue(at: ["paneBorderColor"]) is NSNull)
        #expect(lookup.defaultValue(at: ["terminal", "nope"]) == nil)
    }

    @Test("setting presets validate as partial settings documents")
    func settingPresetsValidateAgainstRoot() throws {
        let validator = CmuxConfigSemanticValidator(scope: .global)
        let valid = validator.validate(jsonObject: [
            "settingPresets": [
                "sidebar.quiet": ["sidebar": ["showPorts": false, "showLog": false]],
                "scroll.fast": ["terminal": ["scrollSpeed": 1.8]],
            ],
        ])
        #expect(valid.isEmpty, "\(valid)")

        let wrongType = validator.validate(jsonObject: [
            "settingPresets": ["bad": ["sidebar": ["showPorts": "no"]]],
        ])
        #expect(wrongType.contains { $0.path.contains("showPorts") })

        let structural = validator.validate(jsonObject: [
            "settingPresets": ["bad": ["actions": [:]]],
        ])
        #expect(!structural.isEmpty)

        let projectScoped = CmuxConfigSemanticValidator(scope: .project).validate(jsonObject: [
            "settingPresets": ["p": ["sidebar": ["showPorts": false]]],
        ])
        #expect(!projectScoped.isEmpty)
    }
}
