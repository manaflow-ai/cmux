import CmuxNextSettings
import Foundation
import Testing

/// `computerUse.mode` and `computerUse.phoneAlwaysAllow` (docs/computer-use-approvals.md): standard
/// (per-app asking off, decision D24) and off by default, read from cmux.json, and never an agent's
/// to change.
struct ComputerUseApprovalSettingsTests {
    @Test func defaultsStandardAndNoPhoneAlways() {
        let settings = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).computerUse
        #expect(settings.mode == .standard)
        #expect(!settings.phoneAlwaysAllow)
    }

    @Test func readsBothKeysAndRefusesAnUnknownMode() throws {
        let parsed = CmuxConfigSnapshot.parse(try JSONValue.parse(Data(#"{"computerUse":{"mode":"bounded","phoneAlwaysAllow":true}}"#.utf8)),
                                              validDensities: [], validMetrics: [])
        #expect(parsed.computerUse.mode == .bounded)
        #expect(parsed.computerUse.phoneAlwaysAllow)
        let unknown = CmuxConfigSnapshot.parse(try JSONValue.parse(Data(#"{"computerUse":{"mode":"yolo"}}"#.utf8)),
                                               validDensities: [], validMetrics: [])
        #expect(unknown.computerUse.mode == .standard, "an unknown mode is ignored: the default applies")
    }

    @Test func agentsCannotRaiseTrust() throws {
        for key in ["computerUse.mode", "computerUse.phoneAlwaysAllow"] {
            #expect(SettingsSchema.agentRefusedKeys[key] == .userOnly, "\(key)")
            #expect(!SettingsSchema.agentSettableKeys.contains(key), "\(key)")
            let descriptor = try #require(SettingsSchema.all.first { $0.id == key })
            #expect(!SettingWriter.caller("mcp").mayWrite(descriptor))
            #expect(!SettingWriter.caller("cli").mayWrite(descriptor))
            #expect(SettingWriter.user.mayWrite(descriptor))
        }
    }
}
