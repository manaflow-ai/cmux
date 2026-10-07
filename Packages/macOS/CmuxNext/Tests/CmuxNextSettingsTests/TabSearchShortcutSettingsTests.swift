import CmuxNextActions
import CmuxNextSettings
import Testing

/// Search Tabs rebinds from cmux.json like every action:
/// `shortcuts.bindings."tab.search"`, and `null` unbinds it.
@Suite struct TabSearchShortcutSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func rebindsAndUnbindsSearchTabs() throws {
        let rebound = try parse(#"{"shortcuts": {"bindings": {"tab.search": "cmd+shift+f"}}}"#)
        #expect(rebound.diagnostics.isEmpty)
        #expect(rebound.shortcuts["tab.search"] != nil)
        let unbound = try parse(#"{"shortcuts": {"bindings": {"tab.search": null}}}"#)
        #expect(unbound.diagnostics.isEmpty)
        #expect(unbound.shortcuts["tab.search"] != nil)
        #expect(try parse("{}").shortcuts["tab.search"] == nil)
    }
}
