import CmuxNextSettings
import Testing

/// React UIs lead review of S4 (P2-3): the diff page's display keys are schema rows, read by
/// cmux-next and settable by agents (looks only), with the page's own defaults. The collapsed
/// files are not a setting; they live in the diff host's store next to the viewed marks (P2-4).
struct DiffViewerSettingsSchemaTests {
    static let toggles: [(String, Bool)] = [
        ("wordWrap", false), ("wordDiffs", false), ("lineNumbers", true), ("showBackgrounds", true), ("expandUnchanged", false),
    ]
    static let choices: [(String, String, [String])] = [
        ("layout", "unified", ["split", "unified"]), ("diffIndicators", "bars", ["bars", "classic", "none"]),
    ]

    @Test func everyDiffDisplayKeyIsASchemaRow() throws {
        for (key, value) in Self.toggles {
            let row = try #require(SettingsSchema.descriptor(for: ["diff", key]), "diff.\(key)")
            #expect(row.kind == .toggle, "diff.\(key)")
            #expect(row.defaultValue == .bool(value), "diff.\(key)")
            #expect(row.consumers == [.cmuxNext], "diff.\(key)")
            #expect(SettingsSchema.agentSettable(row) == true, "diff.\(key)")
        }
        for (key, value, allowed) in Self.choices {
            let row = try #require(SettingsSchema.descriptor(for: ["diff", key]), "diff.\(key)")
            guard case .choice(let options) = row.kind else { Issue.record("diff.\(key) is not a choice"); continue }
            #expect(options.map(\.value) == allowed, "diff.\(key)")
            #expect(row.defaultValue == .string(value), "diff.\(key)")
            #expect(row.consumers == [.cmuxNext], "diff.\(key)")
            #expect(SettingsSchema.agentSettable(row) == true, "diff.\(key)")
        }
        #expect(SettingsSchema.descriptor(for: ["diff", "collapsedFiles"]) == nil)
    }
}
