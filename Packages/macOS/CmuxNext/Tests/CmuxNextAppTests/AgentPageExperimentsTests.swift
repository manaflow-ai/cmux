import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Settings > Advanced > Experiments: every `experiments.*` toggle of the schema reaches the agent
/// pages by name, off unless cmux.json turns it on, so a new prototype needs only its schema row.
@Suite
@MainActor
struct AgentPageExperimentsTests {
    @Test func glassToolbarGroupsIsOffByDefault() {
        #expect(AgentPanePageSettings.experimentToggles.map(\.id).contains("experiments.glassToolbarGroups"))
        #expect(AgentPanePageSettings.experimentSwitches(.object([:]))["glassToolbarGroups"] == false)
    }

    @Test func cmuxJsonTurnsASwitchOn() throws {
        let root = try JSONValue.parse(Data(#"{"experiments":{"glassToolbarGroups":true,"unknown":true}}"#.utf8))
        let switches = AgentPanePageSettings.experimentSwitches(root)
        #expect(switches["glassToolbarGroups"] == true)
        // Only the schema's rows go to the page.
        #expect(switches["unknown"] == nil)
    }

    @Test func aValueThatIsNoBoolIsTheDefault() throws {
        let root = try JSONValue.parse(Data(#"{"experiments":{"glassToolbarGroups":"yes"}}"#.utf8))
        #expect(AgentPanePageSettings.experimentSwitches(root)["glassToolbarGroups"] == false)
    }
}
