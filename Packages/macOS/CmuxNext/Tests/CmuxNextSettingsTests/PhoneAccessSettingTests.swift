import CmuxNextSettings
import Testing

/// `phone.*` (Settings > Accounts > Phone Access): the Mac stays awake for an iPhone on
/// adapter power by default, and no agent changes it. The iroh listener's
/// `phone.allowConnections` and `phone.startSessions` are retired.
struct PhoneAccessSettingTests {
    private static func parse(_ phone: [String: JSONValue]?) -> CmuxConfigSnapshot {
        let root: JSONValue = phone.map { .object(["phone": .object($0)]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func defaults() {
        #expect(Self.parse(nil).sessions.phoneKeepAwake == .pluggedIn)
    }

    @Test func eachKeyLoads() {
        let sessions = Self.parse(["keepAwake": .string("always")]).sessions
        #expect(sessions.phoneKeepAwake == .always)
    }

    /// An old cmux.json that still sets the listener's keys loads without a diagnostic, and a
    /// new value for them is refused as removed.
    @Test func theListenerKeysAreRetired() {
        let snapshot = Self.parse(["allowConnections": .bool(true), "startSessions": .bool(false)])
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("phone.") })
        #expect(snapshot.retiredKeys == ["phone.allowConnections", "phone.startSessions"])
        #expect(SettingsSchema.retiredKeys["phone.allowConnections"] != nil)
        #expect(SettingsSchema.retiredKeys["phone.startSessions"] != nil)
        #expect(SettingsSchema.descriptor(for: ["phone", "allowConnections"]) == nil)
        #expect(SettingsSchema.descriptor(for: ["phone", "startSessions"]) == nil)
        #expect(SettingsSchema.agentRefusedKeys["phone.allowConnections"] == nil)
    }

    @Test func noAgentChangesPhoneAccess() {
        #expect(SettingsSchema.agentRefusedKeys["phone.keepAwake"] == .userOnly)
        // Workspace names leave the Mac for the Cloud service only when the person turns it on.
        #expect(SettingsSchema.agentRefusedKeys["phone.cloudReplica"] == .privacy)
        // A phone views the Cloud machine's screen only when the person turns it on.
        #expect(SettingsSchema.agentRefusedKeys["phone.cloudDesktop"] == .privacy)
    }

    @Test func theRowsShowUnderMobile() throws {
        // Beside the iPhone host's own switch, on Settings > Mobile (2026-11-11).
        let mobile = try #require(SettingsPageLayout().categories().first { $0.spec.id == "mobile" })
        let rows = mobile.groups.flatMap(\.rows).filter { $0.hasPrefix("phone.") }
        #expect(rows == ["phone.keepAwake", "phone.cloudReplica", "phone.cloudDesktop"])
        // Opt-in until #13742 decides the default.
        #expect(SettingsSchema.descriptor(for: ["phone", "cloudReplica"])?.defaultValue == .bool(false))
        #expect(SettingsSchema.descriptor(for: ["phone", "cloudDesktop"])?.defaultValue == .bool(false))
    }
}
