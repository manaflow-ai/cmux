import CmuxNextSettings
import Testing

/// New Tab has no widgets (Lawrence 2026-11-09: "remove widgets completely"), so nothing reads
/// `tabs.newTabWidgets.*`. Each key is retired: an old cmux-next.json that still turns widgets on
/// loads with no diagnostic, Settings offers no row for them, and a write says they were removed.
struct NewTabWidgetsRetiredTests {
    static let keys = ["greeting", "projects", "actions", "chats", "styleDots", "weather", "weatherCity",
                       "machines", "clock", "timer", "warmGreeting", "quote", "order"]

    @Test func anOldWidgetConfigLoadsWithoutADiagnostic() {
        let widgets: [String: JSONValue] = [
            "warmGreeting": .bool(true), "clock": .bool(true), "timer": .bool(true),
            "weatherCity": .string("Berlin"), "order": .array([.string("bogus")]), "greeting": .string("not a bool"),
        ]
        let root = JSONValue.object(["tabs": .object(["newTabWidgets": .object(widgets)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("tabs.newTabWidgets") })
        #expect(snapshot.retiredKeys == widgets.keys.map { "tabs.newTabWidgets.\($0)" }.sorted())
    }

    @Test(arguments: keys)
    func settingsHasNoWidgetRow(_ name: String) {
        let path = ["tabs", "newTabWidgets", name]
        #expect(SettingsSchema.descriptor(for: path) == nil)
        #expect(SettingsSchema.isRetired(path))
        #expect(!SettingsSchema.agentSettableKeys.contains(path.joined(separator: ".")))
    }
}
