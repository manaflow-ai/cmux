import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `tips.state` (feature tips, leo-workspace design/feature-tips.md): the page reads the app's
/// records and keeps one at a time; a closed or used tip stays so, and the page keeps nothing else.
struct AgentPaneFeatureTipsTests {
    private func records() -> AgentPaneFeatureTipRecords {
        let suite = "AgentPaneFeatureTipsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AgentPaneFeatureTipRecords(defaults: defaults)
    }

    @Test func noParamsReadsAndIdStateKeeps() {
        #expect(AgentPaneRequest(body: ["method": "tips.state"]) == .featureTips(id: nil, state: nil))
        #expect(AgentPaneRequest(body: ["method": "tips.state", "params": [:] as [String: Any]]) == .featureTips(id: nil, state: nil))
        let keep = AgentPaneRequest(body: ["method": "tips.state", "params": ["id": "agents-drive-visible-browser-tabs", "state": "shown:2"]])
        #expect(keep == .featureTips(id: "agents-drive-visible-browser-tabs", state: "shown:2"))
    }

    @Test func anythingElseIsRefused() {
        let refused: [[String: Any]] = [
            ["id": "tip"], ["state": "closed"], ["id": "Tip", "state": "closed"], ["id": "tip", "state": "open"],
            ["id": "tip", "state": "shown:0"], ["id": "tip", "state": "shown:100"], ["id": "../tip", "state": "used"],
            ["id": String(repeating: "a", count: 81), "state": "used"], ["id": 3, "state": "used"],
        ]
        for params in refused {
            #expect(AgentPaneRequest(body: ["method": "tips.state", "params": params]) == .unsupported("tips.state"))
        }
    }

    @Test func closedAndUsedStaySo() {
        let store = records()
        store.keep("a", "shown:1")
        store.keep("a", "closed")
        store.keep("a", "shown:2")
        store.keep("b", "used")
        store.keep("b", "shown:1")
        #expect(store.records == ["a": "closed", "b": "used"])
    }

    @Test func recordsAreBounded() {
        let store = records()
        for index in 0..<(AgentPaneFeatureTipRecords.maxRecords + 4) { store.keep("tip-\(index)", "shown:1") }
        #expect(store.records.count == AgentPaneFeatureTipRecords.maxRecords)
        #expect(store.keep("tip-0", "closed")["tip-0"] == "closed")
    }

    @Test func thePageCanCallIt() {
        #expect(AgentPageOps.methods["tips.state"] == "tips.state")
    }

    @Test func theChatFollowsTheToggle() {
        let root = JSONValue.object(["updates": .object(["showFeatureTips": .bool(false)])])
        #expect(AgentPaneDisplaySetting(fileRoot: root).values["updates.showFeatureTips"] == .bool(false))
    }
}
