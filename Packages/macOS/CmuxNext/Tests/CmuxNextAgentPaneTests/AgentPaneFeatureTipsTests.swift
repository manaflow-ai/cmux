import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `tips.state` (feature tips, leo-workspace design/feature-tips.md): the page reads the app's
/// records and keeps one at a time; a closed or used tip stays so, and the page keeps nothing else.
struct AgentPaneFeatureTipsTests {
    private func defaults() throws -> UserDefaults {
        let suite = "AgentPaneFeatureTipsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func records(launch: String = "1@1") throws -> AgentPaneFeatureTipRecords {
        AgentPaneFeatureTipRecords(defaults: try defaults(), launch: launch)
    }

    @Test func noParamsReadsAndIdStateKeeps() {
        #expect(AgentPaneRequest(body: ["method": "tips.state"]) == .featureTips(.read))
        #expect(AgentPaneRequest(body: ["method": "tips.state", "params": [:] as [String: Any]]) == .featureTips(.read))
        let keep = AgentPaneRequest(body: ["method": "tips.state", "params": ["id": "agents-drive-visible-browser-tabs", "state": "shown:2"]])
        #expect(keep == .featureTips(.keep(id: "agents-drive-visible-browser-tabs", state: "shown:2")))
        let claim = AgentPaneRequest(body: ["method": "tips.state", "params": ["claim": "agents-drive-visible-browser-tabs"]])
        #expect(claim == .featureTips(.claim(id: "agents-drive-visible-browser-tabs")))
    }

    @Test func anythingElseIsRefused() {
        let refused: [[String: Any]] = [
            ["id": "tip"], ["state": "closed"], ["id": "Tip", "state": "closed"], ["id": "tip", "state": "open"],
            ["id": "tip", "state": "shown:0"], ["id": "tip", "state": "shown:100"], ["id": "../tip", "state": "used"],
            ["id": String(repeating: "a", count: 81), "state": "used"], ["id": 3, "state": "used"],
            ["claim": "Tip"], ["claim": 1], ["claim": "tip", "id": "tip"], ["id": "tip", "state": "used", "x": 1],
        ]
        for params in refused {
            #expect(AgentPaneRequest(body: ["method": "tips.state", "params": params]) == .unsupported("tips.state"))
        }
    }

    @Test func closedAndUsedStaySo() throws {
        let store = try records()
        store.keep("a", "shown:1")
        store.keep("a", "closed")
        store.keep("a", "shown:2")
        store.keep("b", "used")
        store.keep("b", "shown:1")
        #expect(store.records == ["a": "closed", "b": "used"])
    }

    @Test func recordsAreBounded() throws {
        let store = try records()
        for index in 0..<(AgentPaneFeatureTipRecords.maxRecords + 4) { store.keep("tip-\(index)", "shown:1") }
        #expect(store.records.count == AgentPaneFeatureTipRecords.maxRecords)
        #expect(store.keep("tip-0", "closed")["tip-0"] == "closed")
    }

    /// One tip per launch, whichever page or window asks; the next launch gets its own.
    @Test func oneClaimPerLaunch() throws {
        let shared = try defaults()
        let first = AgentPaneFeatureTipRecords(defaults: shared, launch: "10@100")
        let otherWindow = AgentPaneFeatureTipRecords(defaults: shared, launch: "10@100")
        #expect(first.claim("a"))
        #expect(!otherWindow.claim("b"))
        #expect(!first.claim("a"))
        #expect(AgentPaneFeatureTipRecords(defaults: shared, launch: "11@200").claim("b"))
    }

    @Test func thePageCanCallIt() {
        #expect(AgentPageOps.methods["tips.state"] == "tips.state")
    }

    @Test func theChatFollowsTheToggle() {
        let root = JSONValue.object(["updates": .object(["showFeatureTips": .bool(false)])])
        #expect(AgentPaneDisplaySetting(fileRoot: root).values["updates.showFeatureTips"] == .bool(false))
    }
}
