@testable import CmuxNextSettings
import Testing

/// acpmux reads only the settings file, so `sessions.allowFullAccess` that MDM or the team policy
/// forces reaches it only through the app's settings push (`_acpmux/chat_settings`
/// `allowFullAccess`, `allowFullAccessManaged`). The push carries the effective value, read strictly.
struct ChatSettingsPushFullAccessTests {
    private func push(file: JSONValue, managed: ManagedPreferences = ManagedPreferences(),
                      team: TeamPolicyLayer = .none) -> JSONValue {
        let effective = EffectiveSettings.merge(file: file, managed: managed, team: team)
        return ChatSettings(effective: effective.root, file: file, managedRoots: [], managedKeys: effective.managedKeys).params
    }

    @Test func aValueMDMForcesBeatsTheFileAndGoesOutManaged() {
        let file: JSONValue = .object(["sessions": .object(["allowFullAccess": .bool(true)])])
        let params = push(file: file, managed: ManagedPreferences(forced: ["sessions.allowFullAccess": .bool(false)]))
        #expect(params["allowFullAccess"]?.boolValue == false, "\(params)")
        #expect(params["allowFullAccessManaged"]?.boolValue == true, "\(params)")
    }

    @Test func theTeamPolicyEnforcedValueGoesOutManaged() {
        let empty: JSONValue = .object(["sessions": .object([:])])
        let params = push(file: empty, team: TeamPolicyLayer(teamName: "Acme", enforced: ["sessions.allowFullAccess": .bool(false)]))
        #expect(params["allowFullAccess"]?.boolValue == false, "\(params)")
        #expect(params["allowFullAccessManaged"]?.boolValue == true, "\(params)")
    }

    @Test func withoutPolicyTheFileValueGoesOutUnmanagedAndStrict() {
        let empty: JSONValue = .object(["sessions": .object([:])])
        #expect(push(file: empty)["allowFullAccess"]?.boolValue == true)
        #expect(push(file: empty)["allowFullAccessManaged"]?.boolValue == false)
        for off: JSONValue in [.bool(false), .number(0), .string("false"), .string("true")] {
            let params = push(file: .object(["sessions": .object(["allowFullAccess": off])]))
            #expect(params["allowFullAccess"]?.boolValue == false, "\(off): \(params)")
            #expect(params["allowFullAccessManaged"]?.boolValue == false, "\(off): \(params)")
        }
    }

    @Test func theSettingReadsStrictly() {
        #expect(SessionSettings.fullAccessAllowed(nil))
        #expect(SessionSettings.fullAccessAllowed(.null))
        #expect(SessionSettings.fullAccessAllowed(.bool(true)))
        for off: JSONValue in [.bool(false), .number(0), .number(1), .string("false"), .string("true")] {
            #expect(!SessionSettings.fullAccessAllowed(off), "\(off)")
        }
    }
}
