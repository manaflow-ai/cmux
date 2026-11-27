@testable import CmuxNextSettings
import Testing

/// A profile or team policy that still sets the Session Info row's old key,
/// `agentPane.display.inspector.placement`, keeps its value and its lock on the row's new key,
/// `agentPane.display.sessionInfo.placement`.
struct SessionInfoPlacementManagedKeyTests {
    private let old = "agentPane.display.inspector.placement"
    private let new = "agentPane.display.sessionInfo.placement"

    @Test func anMDMForcedOldKeyLocksTheNewRow() {
        let effective = EffectiveSettings.merge(file: .object([:]), managed: ManagedPreferences(forced: [old: .string("push")]), team: .none)
        #expect(effective.root.value(at: ["agentPane", "display", "sessionInfo", "placement"]) == .string("push"))
        #expect(effective.managedKeys[new] == .device)
        #expect(CFManagedPreferenceReader.readKeys.contains(old))
    }

    @Test func aTeamEnforcedOldKeyLocksTheNewRow() {
        let team = TeamPolicyLayer(teamName: "Acme", enforced: [old: .string("push")])
        let effective = EffectiveSettings.merge(file: .object([:]), managed: ManagedPreferences(), team: team)
        #expect(effective.root.value(at: ["agentPane", "display", "sessionInfo", "placement"]) == .string("push"))
        #expect(effective.managedKeys[new] == .team("Acme"))
    }
}
