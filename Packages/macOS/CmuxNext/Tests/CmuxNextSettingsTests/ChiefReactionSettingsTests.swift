import CmuxNextSettings
import Testing

/// `chief.reactionsCanWake` and `chief.reactionClassifier.*` (Lawrence 2026-10-21, a416): a tapback the
/// person puts on a Chief message goes through a cheap classifier first, which decides whether it starts a
/// turn. On by default, on Claude Haiku, with the host's Claude route and the built-in prompt. The Chief host
/// reads these keys at each decision; a Chief's own engine.json fields override them.
struct ChiefReactionSettingsTests {
    @Test func onByDefaultOnClaudeHaiku() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.chiefReactions == ChiefReactionSettings(canWake: true, harness: "", model: "claude-haiku-5-5", prompt: ""))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func theRowsMatchTheParser() throws {
        let rows: [([String], JSONValue)] = [
            (ChiefReactionSettings.canWakePath, .bool(true)),
            (ChiefReactionSettings.harnessPath, .string("")),
            (ChiefReactionSettings.modelPath, .string("claude-haiku-5-5")),
            (ChiefReactionSettings.promptPath, .string("")),
        ]
        let chief = try #require(SettingsPageLayout().categories().first { $0.spec.id == "chief" })
        for (path, value) in rows {
            let row = try #require(SettingsSchema.descriptor(for: path), "\(path) is a schema row")
            #expect(row.defaultValue == value, "\(path): the row's default is the parser's")
            #expect(row.palette == .exposed, "\(path) has a palette row")
            #expect(SettingsSchema.agentSettable(row) == true, "\(path): a Chief may configure it")
            #expect(chief.groups.contains { $0.rows.contains(row.id) }, "\(path) shows in Settings > Chief")
        }
    }

    @Test func cmuxJSONSetsEachKey() {
        let root = JSONValue.object(["chief": .object([
            "reactionsCanWake": .bool(false),
            "reactionClassifier": .object(["harness": .string("codex"), "model": .string("gpt-5.5-mini"), "prompt": .string("Wake only for questions.")]),
        ])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.chiefReactions == ChiefReactionSettings(canWake: false, harness: "codex", model: "gpt-5.5-mini", prompt: "Wake only for questions."))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func aWrongTypeIsTheDefaultWithADiagnostic() {
        let root = JSONValue.object(["chief": .object(["reactionsCanWake": .string("yes"), "reactionClassifier": .object(["model": .bool(true)])])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.chiefReactions.canWake == true)
        #expect(snapshot.chiefReactions.model == "claude-haiku-5-5")
        #expect(snapshot.diagnostics.contains { $0.path == "chief.reactionsCanWake" })
        #expect(snapshot.diagnostics.contains { $0.path == "chief.reactionClassifier.model" })
    }
}
