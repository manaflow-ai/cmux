import Foundation
import Testing
@testable import CmuxMobileAgentChat
@testable import CmuxMobileLive

/// Full verify D4 (live recheck): a running Codex chat on the phone had no model menu. The phone
/// read the session's models and modes only from later updates, never from `_acpmux/attach`'s
/// session detail, where acpmux keeps them (`models`, `modes`, `configOptions`).
@MainActor
@Suite struct SessionStateTests {
    func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func attachCarriesModelsModesAndOptions() throws {
        let detail = try json("""
        {"models": {"currentModelId": "gpt-5.5", "availableModels": [{"modelId": "gpt-5.5", "name": "GPT-5.5"}, {"modelId": "gpt-6-astra", "name": "GPT-6 Astra"}]},
         "modes": {"currentModeId": "ask", "availableModes": [{"id": "ask", "name": "Ask"}, {"id": "auto", "name": "Auto"}]},
         "configOptions": [{"id": "effort", "name": "Reasoning", "category": "thought_level", "currentValue": "medium", "type": "select",
                            "options": [{"value": "low", "name": "low"}, {"value": "medium", "name": "medium"}]}]}
        """)
        let events = AcpmuxSessionSource.sessionState(detail)
        #expect(events.contains(.modelsAvailable([ACPModelInfo(id: "gpt-5.5", name: "GPT-5.5"), ACPModelInfo(id: "gpt-6-astra", name: "GPT-6 Astra")],
                                                 current: "gpt-5.5")))
        #expect(events.contains(.modesAvailable([ACPMode(id: "ask", name: "Ask"), ACPMode(id: "auto", name: "Auto")], current: "ask")))
        #expect(events.contains { if case .update(.configOptions(let options)) = $0 { return options.first?.isEffort == true }; return false })
    }

    /// A harness that offers its model as a config option (category `model`) still gets a menu.
    @Test func aModelConfigOptionIsTheModelList() throws {
        let detail = try json("""
        {"configOptions": [{"id": "model", "name": "Model", "category": "model", "currentValue": "gpt-5.5", "type": "select",
                            "options": [{"value": "gpt-5.5", "name": "GPT-5.5"}, {"value": "gpt-6-astra"}]}]}
        """)
        let events = AcpmuxSessionSource.sessionState(detail)
        #expect(events.contains(.modelsAvailable([ACPModelInfo(id: "gpt-5.5", name: "GPT-5.5"), ACPModelInfo(id: "gpt-6-astra", name: "gpt-6-astra")],
                                                 current: "gpt-5.5")))
    }

    @Test func nothingKnownIsNothing() throws {
        #expect(AcpmuxSessionSource.sessionState(try json(#"{"models": null, "modes": null, "configOptions": null}"#)).isEmpty)
    }
}
