import CmuxNextSettings
import Testing

/// `sessions.allowFullAccess`: on by default (today's behavior); off is the
/// person's choice, which no agent may undo.
struct FullAccessSettingTests {
    @Test func onByDefaultAndOffLoads() {
        #expect(CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).sessions.allowsFullAccess)
        let off: JSONValue = .object(["sessions": .object(["allowFullAccess": .bool(false)])])
        #expect(!CmuxConfigSnapshot.parse(off, validDensities: [], validMetrics: []).sessions.allowsFullAccess)
    }

    @Test func noAgentTurnsItBackOn() throws {
        #expect(SettingsSchema.agentRefusedKeys["sessions.allowFullAccess"] == .destructive)
        let agents = try #require(SettingsPageLayout().categories().first { $0.spec.id == "agents" })
        #expect(agents.groups.contains { $0.rows.contains("sessions.allowFullAccess") })
    }
}
