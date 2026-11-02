import CmuxNextSettings
import Testing

/// `phone.*` (Settings > Accounts > Phone Access): off until the person turns
/// it on, then paired phones may start workspaces and keep the Mac awake on
/// adapter power. No agent may open phone access.
struct PhoneAccessSettingTests {
    private static func parse(_ phone: [String: JSONValue]?) -> CmuxConfigSnapshot {
        let root: JSONValue = phone.map { .object(["phone": .object($0)]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offUntilTurnedOn() {
        let sessions = Self.parse(nil).sessions
        #expect(!sessions.allowsPhone)
        #expect(sessions.phoneStartsSessions)
        #expect(sessions.phoneKeepAwake == .pluggedIn)
    }

    @Test func eachKeyLoads() {
        let sessions = Self.parse(["allowConnections": .bool(true), "startSessions": .bool(false),
                                   "keepAwake": .string("always")]).sessions
        #expect(sessions.allowsPhone)
        #expect(!sessions.phoneStartsSessions)
        #expect(sessions.phoneKeepAwake == .always)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(["allowConnections": .string("yes")])
        #expect(!snapshot.sessions.allowsPhone)
        #expect(snapshot.diagnostics.contains { $0.path == "phone.allowConnections" })
    }

    @Test func noAgentOpensPhoneAccess() {
        #expect(SettingsSchema.agentRefusedKeys["phone.allowConnections"] == .network)
        #expect(SettingsSchema.agentRefusedKeys["phone.startSessions"] == .network)
        #expect(SettingsSchema.agentRefusedKeys["phone.keepAwake"] == .userOnly)
        // Workspace names leave the Mac for the Cloud service only when the person turns it on.
        #expect(SettingsSchema.agentRefusedKeys["phone.cloudReplica"] == .privacy)
    }

    @Test func theRowsShowUnderAccountsWithTheDisclosure() throws {
        let accounts = try #require(SettingsPageLayout().categories().first { $0.spec.id == "accounts" })
        let rows = accounts.groups.flatMap(\.rows).filter { $0.hasPrefix("phone.") }
        #expect(rows == ["phone.allowConnections", "phone.startSessions", "phone.keepAwake", "phone.cloudReplica"])
        // Opt-in until #13742 decides the default.
        #expect(SettingsSchema.descriptor(for: ["phone", "cloudReplica"])?.defaultValue == .bool(false))
        let toggle = try #require(SettingsSchema.descriptor(for: ["phone", "allowConnections"]))
        #expect(toggle.defaultValue == .bool(false))
        #expect(toggle.help?.contains("is sent to cmux servers") == true)
        // The cloud copy is the one exception to "not sent": the help names what is stored.
        #expect(toggle.help?.contains("unread count and whether it is active") == true)
    }
}
