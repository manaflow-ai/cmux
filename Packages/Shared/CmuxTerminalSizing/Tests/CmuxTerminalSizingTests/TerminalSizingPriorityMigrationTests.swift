import CmuxTerminalSizing
import Testing

/// Stored policies may hold legacy `<user>/<kind>` keys. An edit replaces
/// each with the per-device keys of the participants it matches, so a
/// reordered list ranks two Macs of one user separately.
struct TerminalSizingPriorityMigrationTests {
    private let studio = TerminalSizingParticipant(id: "a", userID: "u1", deviceKind: .mac, deviceID: "studio")
    private let laptop = TerminalSizingParticipant(id: "b", userID: "u1", deviceKind: .mac, deviceID: "laptop")
    private let phone = TerminalSizingParticipant(id: "c", userID: "u1", deviceKind: .iphone, deviceID: "p1")
    private let legacyTUI = TerminalSizingParticipant(id: "t", deviceKind: .tui)

    @Test func legacyKeysExpandToEachMatchingDeviceInPlace() {
        let policy = TerminalSizingPolicy(mode: .priority, priority: ["u1/iphone", "u1/mac", "u9/mac"])
        let migrated = policy.migratingLegacyPriorityKeys([studio, laptop, phone, legacyTUI])
        #expect(migrated.priority == ["u1/iphone/p1", "u1/mac/studio", "u1/mac/laptop", "u9/mac"])
        #expect(migrated.mode == .priority)
    }

    @Test func perDeviceKeysAndDevicesWithoutIDsStay() {
        let policy = TerminalSizingPolicy(mode: .priority, priority: ["u1/mac/laptop", "u1/mac", "anon:t/tui"])
        let migrated = policy.migratingLegacyPriorityKeys([studio, laptop, legacyTUI])
        #expect(migrated.priority == ["u1/mac/laptop", "u1/mac/studio", "anon:t/tui"])
    }
}
