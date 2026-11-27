import CmuxNextSettings
import Testing

/// Settings > Advanced > Experiments: every `experiments.*` toggle of the schema reaches the agent
/// pages by name, off unless cmux.json turns it on, so a new prototype needs only its schema row.
struct ExperimentSwitchesSettingTests {
    private func switches(_ experiments: JSONValue?) -> [String: Bool] {
        let root: JSONValue = experiments.map { .object(["experiments": $0]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).experimentSwitches
    }

    @Test func glassToolbarGroupsIsOffByDefault() {
        #expect(switches(nil)["glassToolbarGroups"] == false)
    }

    @Test func cmuxJsonTurnsASwitchOnAndOnlySchemaRowsGoToThePage() {
        let value = switches(.object(["glassToolbarGroups": .bool(true), "unknown": .bool(true)]))
        #expect(value["glassToolbarGroups"] == true)
        #expect(value["unknown"] == nil)
    }

    @Test func aValueThatIsNoBoolIsTheDefault() {
        #expect(switches(.object(["glassToolbarGroups": .string("yes")]))["glassToolbarGroups"] == false)
    }
}
