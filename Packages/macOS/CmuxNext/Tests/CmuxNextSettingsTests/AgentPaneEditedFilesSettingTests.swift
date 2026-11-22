import Testing
@testable import CmuxNextSettings

/// `agentPane.editedFiles.*` (General > Agent Chat): the agent pane's edited-files card. Each key is a
/// schema row an agent may set (looks only); cmux.json values reach the snapshot, and a bad value is
/// that key's default plus a diagnostic. The page reads the same names (turnChanges/settings.ts).
@Suite struct AgentPaneEditedFilesSettingTests {
    static func snapshot(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func theThreeKeysAreSchemaRowsWithTheCardsDefaults() throws {
        let choices: [(String, String, [String])] = [
            ("show", "always", ["always", "collapsed", "never"]), ("scope", "turn", ["turn", "session"]),
        ]
        for (key, value, allowed) in choices {
            let row = try #require(SettingsSchema.descriptor(for: ["agentPane", "editedFiles", key]), "\(key)")
            guard case .choice(let options) = row.kind else { Issue.record("\(key) is not a choice"); continue }
            #expect(options.map(\.value) == allowed, "\(key)")
            #expect(row.defaultValue == .string(value), "\(key)")
            #expect(row.section == .general, "\(key)")
            #expect(SettingsSchema.agentSettable(row) == true, "\(key)")
        }
        let rows = try #require(SettingsSchema.descriptor(for: ["agentPane", "editedFiles", "maxRows"]))
        guard case .number(let number) = rows.kind else { Issue.record("maxRows is not a number"); return }
        #expect(number.range == 1...50)
        #expect(rows.defaultValue == .number(5))
        #expect(SettingsSchema.agentSettable(rows) == true)
    }

    @Test func unsetIsAlwaysFiveRowsPerTurn() throws {
        let setting = try Self.snapshot("{}").agentPaneEditedFiles
        #expect(setting == .fallback)
        #expect(setting.pageValue == ["show": "always", "maxRows": 5, "scope": "turn"])
    }

    @Test func cmuxJSONValuesReachTheSnapshotAndThePage() throws {
        let snapshot = try Self.snapshot(#"{"agentPane": {"editedFiles": {"show": "collapsed", "maxRows": 12, "scope": "session"}}}"#)
        #expect(snapshot.diagnostics.isEmpty)
        #expect(snapshot.agentPaneEditedFiles.pageValue == ["show": "collapsed", "maxRows": 12, "scope": "session"])
    }

    @Test func aBadValueKeepsThatKeysDefaultWithADiagnostic() throws {
        let snapshot = try Self.snapshot(#"{"agentPane": {"editedFiles": {"show": "sometimes", "maxRows": 0, "scope": "session"}}}"#)
        #expect(snapshot.agentPaneEditedFiles.show == "always")
        #expect(snapshot.agentPaneEditedFiles.maxRows == 5)
        #expect(snapshot.agentPaneEditedFiles.scope == "session")
        let paths = snapshot.diagnostics.filter { $0.kind == .invalidValue }.map(\.path).sorted()
        #expect(paths == ["agentPane.editedFiles.maxRows", "agentPane.editedFiles.show"])
    }
}
