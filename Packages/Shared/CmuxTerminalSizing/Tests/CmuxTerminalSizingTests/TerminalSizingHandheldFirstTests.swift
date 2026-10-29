import CmuxTerminalSizing
import Foundation
import Testing

/// "iPhone First" is the default policy. A policy stored or sent before the
/// key existed is an explicit choice and keeps its old behavior.
struct TerminalSizingHandheldFirstTests {
    @Test func defaultPolicyIsHandheldFirstOverFitEveryone() {
        #expect(TerminalSizingPolicy.standard.handheldFirst)
        #expect(TerminalSizingPolicy.standard.mode == .smallest)
        #expect(TerminalSizingEngine(initialSize: TerminalGridSize(cols: 80, rows: 24)).state.policy == .standard)
    }

    @Test func policyWithoutTheKeyDecodesWithHandheldFirstOff() throws {
        let data = Data(#"{"mode":"latest","priority":[],"fixed":null}"#.utf8)
        let policy = try JSONDecoder().decode(TerminalSizingPolicy.self, from: data)
        #expect(policy == .latest)
        #expect(!policy.handheldFirst)
    }

    @Test func policyRoundTripsHandheldFirst() throws {
        let data = try JSONEncoder().encode(TerminalSizingPolicy.standard)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["handheld_first"] as? Bool == true)
        #expect(try JSONDecoder().decode(TerminalSizingPolicy.self, from: data) == .standard)
    }

    @Test func pickingAModeTurnsHandheldFirstOffAndPickingItBackFitsEveryone() {
        let grid = TerminalGridSize(cols: 90, rows: 30)
        let latest = TerminalSizingPolicy.standard.withChoice(.mode(.latest), fallbackFixed: grid)
        #expect(latest == .latest)
        #expect(latest.choice == .mode(.latest))
        let fixed = TerminalSizingPolicy.standard.withChoice(.mode(.fixed), fallbackFixed: grid)
        #expect(fixed.fixed == grid)
        #expect(!fixed.handheldFirst)
        let back = TerminalSizingPolicy(mode: .priority, priority: ["k"]).withChoice(.handheldFirst, fallbackFixed: grid)
        #expect(back == TerminalSizingPolicy(mode: .smallest, priority: ["k"], handheldFirst: true))
        #expect(back.choice == .handheldFirst)
    }

    @Test func pickerListsHandheldFirstThenEveryMode() {
        #expect(TerminalSizingChoice.allCases.first == .handheldFirst)
        #expect(TerminalSizingChoice.allCases.count == TerminalSizingMode.allCases.count + 1)
    }

    @Test func legacyKeyMigrationKeepsHandheldFirst() {
        let policy = TerminalSizingPolicy(mode: .priority, priority: ["u1/mac"], handheldFirst: true)
        let mac = TerminalSizingParticipant(id: "m", userID: "u1", deviceKind: .mac, deviceID: "d")
        #expect(policy.migratingLegacyPriorityKeys([mac]).handheldFirst)
    }
}
