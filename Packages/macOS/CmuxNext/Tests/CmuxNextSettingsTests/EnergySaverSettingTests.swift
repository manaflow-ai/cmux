@testable import CmuxNextSettings
import Testing

/// `energy.saver` (``EnergySaverSetting``): the four modes, `auto` by default, and one schema row
/// whose choices are exactly the modes, refused to agents, on the Settings page in General while the
/// `energySaver` feature is on, with "On Battery" only on a Mac with a battery.
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
        #expect(row.isShownOnSettingsPage)
        #expect(row.isPaletteExposed)
    }

    /// The page shows the row in General > Energy Saver.
    @Test func theRowLivesInGeneral() throws {
        let general = try #require(SettingsPageLayout().categories().first { $0.spec.id == "general" })
        let group = try #require(general.groups.first { $0.key == "settings.group.energy" })
        #expect(group.rows == ["energy.saver"])
    }

    /// While the `energySaver` feature is off the saver never turns on, so neither the page nor the
    /// palette offers the row.
    @Test func theFeatureOffHidesTheRow() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "energy.saver" })
        for hasBattery in [false, true] {
            let availability = EnergySaverSetting().availability(featureEnabled: false, hasBattery: hasBattery)
            #expect(!availability.isShown(row))
            #expect(availability.json == .object(["hidden_rows": .array([.string("energy.saver")]), "hidden_choices": .object([:])]))
        }
    }

    /// A Mac with no battery never runs on battery: "On Battery" is left out, unless it is the value
    /// set now (a cmux-next.json copied from a laptop), so the row still shows what is selected.
    @Test func aMacWithNoBatteryHidesOnBattery() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "energy.saver" })
        let availability = EnergySaverSetting().availability(featureEnabled: true, hasBattery: false)
        #expect(availability.isShown(row))
        let offered = Self.modes.filter { availability.isShown(choice: $0, of: row, current: .string("auto")) }
        #expect(offered == ["auto", "always", "off"])
        #expect(availability.isShown(choice: "onBattery", of: row, current: .string("onBattery")))
        #expect(availability.json == .object(["hidden_rows": .array([]),
                                              "hidden_choices": .object(["energy.saver": .array([.string("onBattery")])])]))
    }

    /// A laptop gets every mode.
    @Test func aMacWithABatteryOffersEveryMode() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "energy.saver" })
        let availability = EnergySaverSetting().availability(featureEnabled: true, hasBattery: true)
        #expect(availability == SettingsAvailability())
        #expect(Self.modes.allSatisfy { availability.isShown(choice: $0, of: row, current: nil) })
    }

    /// What the page draws is what every entry point that names a row may point at: with the feature
    /// off, the row is not on the page, and a refused `energy.saver` value's toast opens the file
    /// instead of a Settings row that is not there.
    @MainActor @Test func aHiddenRowIsNoSettingsTarget() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "energy.saver" })
        let off = EnergySaverSetting().availability(featureEnabled: false, hasBattery: true)
        let on = EnergySaverSetting().availability(featureEnabled: true, hasBattery: false)
        #expect(!off.isShownOnSettingsPage(row))
        #expect(on.isShownOnSettingsPage(row))
        #expect(SettingsDiagnosticToasts.destination("energy.saver", availability: off) == .file)
        #expect(SettingsDiagnosticToasts.destination("energy.saver", availability: on) == .row)
    }

    /// Battery and power are the person's call, like `sessions.keepAwake`, and a write of the setting
    /// ends their "Turn Off Energy Saver for Now": an agent must not do either.
    @Test func agentsCannotSetIt() {
        #expect(SettingsSchema.agentRefusedKeys["energy.saver"] == .userOnly)
        #expect(!SettingsSchema.agentSettableKeys.contains("energy.saver"))
    }
}
