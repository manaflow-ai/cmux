@testable import CmuxNextSettings
import Testing

/// acpmux reads only the settings file, so a `sessions.allowFullAccess` that MDM or the team policy
/// forces reaches it only through the app's settings push (`_acpmux/chat_settings` `allowFullAccess`,
/// `allowFullAccessManaged`). claude-sr2, 2026-10-25: "an MDM-managed value is an upper bound the user
/// can't override ... If MDM is unset, nothing changes."
struct ChatSettingsPushFullAccessTests {
    private func push(file: JSONValue, managed: ManagedPreferences = ManagedPreferences(),
                      team: TeamPolicyLayer = .none) -> JSONValue {
        let effective = EffectiveSettings.merge(file: file, managed: managed, team: team)
        return ChatSettings(effective: effective.root, file: file, managedRoots: [], managedKeys: effective.managedKeys).params
    }

    private let allowed: JSONValue = .object(["sessions": .object(["allowFullAccess": .bool(true)])])

    @Test func anOffMDMForcesGoesOutManagedOverTheFile() {
        let params = push(file: allowed, managed: ManagedPreferences(forced: ["sessions.allowFullAccess": .bool(false)]))
        #expect(params["allowFullAccess"]?.boolValue == false, "\(params)")
        #expect(params["allowFullAccessManaged"]?.boolValue == true, "\(params)")
    }

    @Test func theTeamPolicyEnforcedOffGoesOutManaged() {
        let team = TeamPolicyLayer(teamName: "Acme", enforced: ["sessions.allowFullAccess": .bool(false)])
        let params = push(file: allowed, team: team)
        #expect(params["allowFullAccess"]?.boolValue == false, "\(params)")
        #expect(params["allowFullAccessManaged"]?.boolValue == true, "\(params)")
    }

    @Test func aForcedValueThatIsNotTrueGoesOutOff() {
        for forced: JSONValue in [.string("true"), .number(1)] {
            let params = push(file: allowed, managed: ManagedPreferences(forced: ["sessions.allowFullAccess": forced]))
            #expect(params["allowFullAccess"]?.boolValue == false, "\(forced): \(params)")
            #expect(params["allowFullAccessManaged"]?.boolValue == true, "\(forced): \(params)")
        }
    }

    @Test func withMDMUnsetNothingIsForced() {
        let off: JSONValue = .object(["sessions": .object(["allowFullAccess": .bool(false)])])
        for file in [allowed, off] {
            let params = push(file: file)
            #expect(params["allowFullAccess"] == .null, "\(params)")
            #expect(params["allowFullAccessManaged"]?.boolValue == false, "\(params)")
        }
    }
}
