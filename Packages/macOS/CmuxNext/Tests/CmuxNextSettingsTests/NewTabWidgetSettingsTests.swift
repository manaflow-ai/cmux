import CmuxNextSettings
import Testing

/// `tabs.newTabWidgets.*` (Leo 2026-10-20: "only do the composer for the default"): the New Tab page
/// is the composer alone unless the user turns a widget on (no greeting, Leo 2026-10-22); Settings lists each widget with
/// the other New Tab rows, agents may set them, and a bad value keeps its default with a diagnostic.
struct NewTabWidgetSettingsTests {
    static func parse(_ widgets: [String: JSONValue]?) -> CmuxConfigSnapshot {
        let root: JSONValue = widgets.map { .object(["tabs": .object(["newTabWidgets": .object($0)])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func theDefaultPageIsTheComposerAloneWithNoGreeting() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.newTabWidgets.ids == [])
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    /// A `true` saved while the key drew the time-of-day greeting now turns the headline on.
    @Test func aSavedGreetingTurnsTheHeadlineOn() {
        #expect(Self.parse(["greeting": .bool(true)]).newTabWidgets.ids == ["greeting"])
        #expect(Self.parse(["greeting": .bool(true), "chats": .bool(true)]).newTabWidgets.ids == ["greeting", "chats"])
    }

    /// New Tab picks open, ask or search itself (#22816): an old config's switch key is retired,
    /// so loading stays clean and Settings/agent writes cannot expose it again.
    @Test func theRetiredModeSwitchKeyIsIgnored() {
        let snapshot = Self.parse(["modeSwitch": .bool(true)])
        #expect(snapshot.newTabWidgets.ids == [])
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
        #expect(snapshot.retiredKeys == ["tabs.newTabWidgets.modeSwitch"])
        #expect(SettingsSchema.descriptor(for: ["tabs", "newTabWidgets", "modeSwitch"]) == nil)
        #expect(!SettingsSchema.agentSettableKeys.contains("tabs.newTabWidgets.modeSwitch"))
    }

    @Test func eachWidgetTurnsOnAndTheGreetingOff() {
        let snapshot = Self.parse([
            "greeting": .bool(false), "projects": .bool(true), "actions": .bool(true),
            "chats": .bool(true), "styleDots": .bool(true),
        ])
        #expect(snapshot.newTabWidgets.ids == ["projects", "actions", "chats", "styleDots"])
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    /// A `false` saved before the headline was off by default is told apart from the default, so the
    /// page keeps the composer where it sat for that user (no room for the headline).
    @Test func aSavedFalseGreetingIsToldApartFromTheDefault() {
        #expect(Self.parse(nil).newTabWidgets.greetingTurnedOff == false)
        #expect(Self.parse(["chats": .bool(true)]).newTabWidgets.greetingTurnedOff == false)
        #expect(Self.parse(["greeting": .bool(true)]).newTabWidgets.greetingTurnedOff == false)
        #expect(Self.parse(["greeting": .bool(false)]).newTabWidgets.greetingTurnedOff == true)
        #expect(Self.parse(["greeting": .string("off")]).newTabWidgets.greetingTurnedOff == false)
    }

    @Test func aBadValueKeepsItsDefaultAndSaysWhy() {
        let snapshot = Self.parse(["chats": .string("on")])
        #expect(snapshot.newTabWidgets.ids == [])
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.newTabWidgets.chats" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsEveryWidgetWithTheNewTabRowsAndAgentsMaySetThem() throws {
        let template = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabTemplate"]))
        let defaults: [String: Bool] = [
            "greeting": false, "projects": false, "actions": false, "chats": false, "styleDots": false,
        ]
        for (name, value) in defaults {
            let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabWidgets", name]), "\(name)")
            #expect(descriptor.defaultValue == .bool(value), "\(name)")
            #expect(descriptor.section == template.section && descriptor.group == template.group, "\(name) is not with the New Tab rows")
            #expect(SettingsSchema.agentSettableKeys.contains("tabs.newTabWidgets.\(name)"), "\(name)")
        }
    }
}
