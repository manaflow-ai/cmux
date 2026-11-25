@testable import CmuxNextSettings
import Testing

/// `agentPane.savedPrompts`: prompts by name that every chat's `/` menu offers. acpmux reads them
/// from cmux.json (crates/acpmux/src/prompts.rs); the app's parser only checks the value, so a valid
/// map gives no diagnostic and is never read as a Boolean.
struct AgentPaneSavedPromptsSettingTests {
    @Test func aMapOfNamesToTextsIsKeptWithNoDiagnostic() {
        let prompts = JSONValue.object(["review": .string("Review this diff"), "standup": .string("Summarize {{date}}")])
        let root = JSONValue.object(["agentPane": .object(["savedPrompts": prompts, "showDictation": .bool(false)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.savedPrompts == prompts)
        #expect(snapshot.agentPaneComposer.showDictation == false)
        #expect(!snapshot.diagnostics.contains { $0.path == "agentPane.savedPrompts" })
    }

    @Test func aValueThatIsNotAMapIsTheDefaultWithADiagnostic() {
        for bad: JSONValue in [.bool(true), .string("review"), .number(1)] {
            let root = JSONValue.object(["agentPane": .object(["savedPrompts": bad])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.agentPaneComposer.savedPrompts == .object([:]))
            #expect(snapshot.diagnostics.contains { $0.path == "agentPane.savedPrompts" })
        }
    }
}
