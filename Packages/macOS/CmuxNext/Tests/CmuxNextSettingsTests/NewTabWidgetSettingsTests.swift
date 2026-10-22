import CmuxNextSettings
import Testing

/// `tabs.newTabWidgets.*` (Leo 2026-10-20: "only do the composer for the default"): the New Tab page
/// is a greeting and the composer unless the user turns a widget on; Settings lists each widget with
/// the other New Tab rows, agents may set them, and a bad value keeps its default with a diagnostic.
struct NewTabWidgetSettingsTests {
    static func parse(_ widgets: [String: JSONValue]?) -> CmuxConfigSnapshot {
        let root: JSONValue = widgets.map { .object(["tabs": .object(["newTabWidgets": .object($0)])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func theDefaultPageIsTheGreetingAndTheComposer() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.newTabWidgets.ids == ["greeting"])
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func eachWidgetTurnsOnAndTheGreetingOff() {
        let snapshot = Self.parse([
            "greeting": .bool(false), "projects": .bool(true), "actions": .bool(true),
            "chats": .bool(true), "styleDots": .bool(true),
        ])
        #expect(snapshot.newTabWidgets.ids == ["projects", "actions", "chats", "styleDots"])
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test func aBadValueKeepsItsDefaultAndSaysWhy() {
        let snapshot = Self.parse(["chats": .string("on")])
        #expect(snapshot.newTabWidgets.ids == ["greeting"])
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.newTabWidgets.chats" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsEveryWidgetWithTheNewTabRowsAndAgentsMaySetThem() throws {
        let template = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabTemplate"]))
        let defaults: [String: Bool] = [
            "greeting": true, "projects": false, "actions": false, "chats": false, "styleDots": false,
        ]
        for (name, value) in defaults {
            let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabWidgets", name]), "\(name)")
            #expect(descriptor.defaultValue == .bool(value), "\(name)")
            #expect(descriptor.section == template.section && descriptor.group == template.group, "\(name) is not with the New Tab rows")
            #expect(SettingsSchema.agentSettableKeys.contains("tabs.newTabWidgets.\(name)"), "\(name)")
        }
    }
}
