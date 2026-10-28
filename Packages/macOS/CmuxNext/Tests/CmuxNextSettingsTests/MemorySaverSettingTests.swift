import CmuxNextCompat
@testable import CmuxNextSettings
import Testing

/// `memory.saver` (``MemorySaverSetting``): Chrome's four Memory Saver modes, medium
/// by default, the default written as no key, and one schema row whose choices are exactly the modes,
/// off the Settings page while the kinds it times are behind default-off features, settable by agents
/// like `browser.hibernation`.
struct MemorySaverSettingTests {
    @Test func aMissingOrUnknownValueIsMedium() {
        #expect(MemorySaverSetting().value(in: .object([:])) == .medium)
        #expect(MemorySaverSetting().value(in: .object(["memory": .object(["saver": .string("sometimes")])])) == .medium)
        #expect(MemorySaverSetting().value(in: .object(["memory": .object(["saver": .bool(true)])])) == .medium)
        #expect(MemorySaverSetting().value(in: .object(["memory": .string("off")])) == .medium)
    }

    /// The modes, as cmux-next.json spells them, in the row's order.
    static let modes = ["off", "conservative", "medium", "aggressive"]

    @Test(arguments: modes)
    func everyModeReadsAndWritesBack(mode: String) throws {
        let root = JSONValue.object(["memory": .object(["saver": .string(mode)])])
        let read = MemorySaverSetting().value(in: root)
        #expect(read.rawValue == mode)
        let written = MemorySaverSetting.fileValue(read)
        if read == MemorySaverSetting.defaultValue {
            #expect(written == nil, "the default removes the key")
        } else {
            #expect(written == .string(mode))
        }
    }

    @Test func theSnapshotReadsTheSameValue() {
        let snapshot = CmuxConfigSnapshot.parse(.object(["memory": .object(["saver": .string("aggressive")])]), validDensities: [], validMetrics: [])
        #expect(snapshot.memorySaver == .aggressive)
        #expect(CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).memorySaver == .medium)
    }

    @Test func theSchemaRowOffersEveryModeAndDefaultsToMedium() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "memory.saver" })
        #expect(row.defaultValue == .string("medium"))
        guard case .choice(let choices) = row.kind else {
            Issue.record("memory.saver is not a choice row")
            return
        }
        #expect(choices.map(\.value) == Self.modes)
        #expect(choices.allSatisfy { $0.titleKey != nil }, "every choice title is localized")
        #expect(!row.isShownOnSettingsPage, "the row stays off the page while its kinds are behind default-off features")
        #expect(row.accepts(.string("aggressive")))
        #expect(!row.accepts(.string("sometimes")))
    }

    /// How soon hidden content frees its memory is a performance choice, like `browser.hibernation`.
    @Test func agentsMaySetIt() {
        #expect(SettingsSchema.agentSettableKeys.contains("memory.saver"))
        #expect(SettingsSchema.agentRefusedKeys["memory.saver"] == nil)
    }

    /// Chrome's memory_saver_mode_policy.cc: 6 h, 4 h and 2 h, no proactive discard while off; cmux
    /// keeps the ratios around each kind's medium timeout.
    @Test func theModesScaleAKindsTimeoutAsChromeDoes() {
        let medium = Duration.seconds(600)
        #expect(MemorySaverMode.off.proactiveTimeout(medium) == nil)
        #expect(MemorySaverMode.conservative.proactiveTimeout(medium) == .seconds(900))
        #expect(MemorySaverMode.medium.proactiveTimeout(medium) == medium)
        #expect(MemorySaverMode.aggressive.proactiveTimeout(medium) == .seconds(300))
        #expect(MemorySaverMode.conservative.proactiveTimeoutScale == 6.0 / 4.0)
        #expect(MemorySaverMode.aggressive.proactiveTimeoutScale == 2.0 / 4.0)
    }
}
