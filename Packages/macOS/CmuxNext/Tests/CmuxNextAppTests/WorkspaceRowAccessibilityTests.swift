import AppKit
@testable import CmuxNextSidebar
import Testing

/// Workspace rows expose the same selection state that the sidebar paints, so VoiceOver can
/// distinguish the active workspace and rows included in a multi-selection.
@MainActor
struct WorkspaceRowAccessibilityTests {
    /// A row as the list shows it: `configure` makes a workspace row an
    /// accessibility element with the row role; these tests set that directly.
    private func accessibleRow<Row: SidebarRowView>(_ type: Row.Type) -> Row {
        let row = Row(key: .workspace(WorkspaceID("workspace")))
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.row)
        return row
    }

    @Test func baseRowExposesItsSelection() {
        let row = accessibleRow(SidebarRowView.self)

        row.isSelected = true
        #expect(row.isAccessibilitySelected())

        row.isSelected = false
        #expect(!row.isAccessibilitySelected())
    }

    @Test func selectedAndSecondaryRowsExposeTheirSelection() {
        let row = accessibleRow(WorkspaceRowView.self)

        row.isSelected = true
        #expect(row.isAccessibilitySelected())

        row.isSelected = false
        row.isSecondarySelected = true
        #expect(row.isAccessibilitySelected())

        row.isSecondarySelected = false
        #expect(!row.isAccessibilitySelected())
    }

    /// Either flag alone keeps the row selected: clearing one while the other holds must not
    /// clear AXSelected, whichever was set first.
    @Test(arguments: [true, false])
    func clearingOneSelectionKeepsTheOther(primaryFirst: Bool) {
        let row = accessibleRow(WorkspaceRowView.self)
        func set(primary: Bool) {
            if primary { row.isSelected = true } else { row.isSecondarySelected = true }
            #expect(row.isAccessibilitySelected())
        }
        // Both set: clear the primary flag first, then the secondary.
        set(primary: primaryFirst)
        set(primary: !primaryFirst)
        row.isSelected = false
        #expect(row.isAccessibilitySelected())
        row.isSecondarySelected = false
        #expect(!row.isAccessibilitySelected())

        // Both set again: clear the secondary flag first, then the primary.
        set(primary: primaryFirst)
        set(primary: !primaryFirst)
        row.isSecondarySelected = false
        #expect(row.isAccessibilitySelected())
        row.isSelected = false
        #expect(!row.isAccessibilitySelected())
    }
}
