import CmuxNextSettings
import Testing

/// The Weather and Machines widgets (`tabs.newTabWidgets.weather|weatherCity|machines`): off by
/// default, named in the page's widget list when on, and the weather's two keys stay the person's
/// (they reach Open-Meteo and ask for location), so agents may not set them.
struct NewTabWeatherMachinesSettingsTests {
    static func parse(_ widgets: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["tabs": .object(["newTabWidgets": .object(widgets)])]), validDensities: [], validMetrics: [])
    }

    @Test func weatherAndMachinesAreOffByDefault() {
        let widgets = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).newTabWidgets
        #expect(!widgets.weather && !widgets.machines && widgets.weatherCity.isEmpty)
        #expect(!widgets.ids.contains("weather") && !widgets.ids.contains("machines"))
    }

    @Test func turnedOnTheyFollowTheOtherWidgetsAndTheCityIsTrimmed() {
        let snapshot = Self.parse([
            "greeting": .bool(false), "weather": .bool(true), "machines": .bool(true), "weatherCity": .string("  Berlin \n"),
        ])
        #expect(snapshot.newTabWidgets.ids == ["weather", "machines"])
        #expect(snapshot.newTabWidgets.weatherCity == "Berlin")
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsThemAndOnlyMachinesIsAgentSettable() throws {
        let city = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabWidgets", "weatherCity"]))
        #expect(city.defaultValue == .string(""))
        for name in ["weather", "machines"] {
            let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabWidgets", name]), "\(name)")
            #expect(descriptor.defaultValue == .bool(false), "\(name)")
        }
        #expect(SettingsSchema.agentSettableKeys.contains("tabs.newTabWidgets.machines"))
        #expect(!SettingsSchema.agentSettableKeys.contains("tabs.newTabWidgets.weather"))
        #expect(!SettingsSchema.agentSettableKeys.contains("tabs.newTabWidgets.weatherCity"))
    }
}
