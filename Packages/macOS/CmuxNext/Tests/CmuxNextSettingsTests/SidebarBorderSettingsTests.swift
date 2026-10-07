import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `sidebar.border` and `sidebar.borderWidth` in cmux-next.json (R93).
@Suite struct SidebarBorderSettingsTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: ["compact"], validMetrics: [])
    }

    @Test func unsetIsNoBorder() throws {
        #expect(try parse("{}").sidebarBorder == SidebarBorder())
    }

    @Test func parsesTheToggleAndTheWidth() throws {
        let snapshot = try parse(#"{"sidebar": {"border": true, "borderWidth": 2}}"#)
        #expect(snapshot.sidebarBorder == SidebarBorder(shows: true, width: 2))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func badValuesAreSkippedWithDiagnostics() throws {
        let snapshot = try parse(#"{"sidebar": {"border": "yes", "borderWidth": 9}}"#)
        #expect(snapshot.sidebarBorder == SidebarBorder(shows: false, width: 4))  // width clamped
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["sidebar.border", "sidebar.borderWidth"])
    }

    @Test func theSchemaListsBothKeys() throws {
        let border = try #require(SettingsSchema.descriptor(for: ["sidebar", "border"]))
        #expect(border.kind == .toggle)
        #expect(border.defaultValue == .bool(false))
        let width = try #require(SettingsSchema.descriptor(for: ["sidebar", "borderWidth"]))
        guard case .number(let number) = width.kind else {
            Issue.record("expected a number, got \(width.kind)")
            return
        }
        #expect(number.range == 0.5...4)
    }
}
