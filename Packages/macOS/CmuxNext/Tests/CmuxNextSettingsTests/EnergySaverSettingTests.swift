@testable import CmuxNextSettings
import Testing

/// `energy.saver` (``EnergySaverSetting``): the four modes, `auto` by default, and one schema row
/// whose choices are exactly the modes, refused to agents.
struct EnergySaverSettingTests {
    @Test func aMissingOrUnknownValueIsAuto() {
        #expect(EnergySaverSetting().value(in: .object([:])) == .auto)
        #expect(EnergySaverSetting().value(in: .object(["energy": .object(["saver": .string("sometimes")])])) == .auto)
        #expect(EnergySaverSetting().value(in: .object(["energy": .object(["saver": .bool(true)])])) == .auto)
    }

    /// The modes, as cmux-next.json spells them.
    static let modes = ["auto", "onBattery", "always", "off"]

    @Test(arguments: modes)
    func everyModeReads(mode: String) {
        let root = JSONValue.object(["energy": .object(["saver": .string(mode)])])
        #expect(EnergySaverSetting().value(in: root).rawValue == mode)
    }

    @Test func theSchemaRowOffersEveryModeAndDefaultsToAuto() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "energy.saver" })
        #expect(row.defaultValue == .string("auto"))
        guard case .choice(let choices) = row.kind else {
            Issue.record("energy.saver is not a choice row")
            return
        }
        #expect(choices.map(\.value) == Self.modes)
        #expect(choices.allSatisfy { $0.titleKey != nil })
        #expect(!row.isShownOnSettingsPage, "the row stays off the page until p14-energy-129")
    }

    /// Battery and power are the person's call, like `sessions.keepAwake`, and a write of the setting
    /// ends their "Turn Off Energy Saver for Now": an agent must not do either.
    @Test func agentsCannotSetIt() {
        #expect(SettingsSchema.agentRefusedKeys["energy.saver"] == .userOnly)
        #expect(!SettingsSchema.agentSettableKeys.contains("energy.saver"))
    }
}
