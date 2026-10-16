import AppKit
@testable import CmuxNextSidebar
import Testing

/// Workspace rows expose the same selection state that the sidebar paints, so VoiceOver can
/// distinguish the active workspace and rows included in a multi-selection.
@MainActor
struct WorkspaceRowAccessibilityTests {
    @Test func selectedAndSecondaryRowsExposeTheirSelection() {
        let row = WorkspaceRowView(key: .workspace(WorkspaceID("workspace")))
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.row)

        row.isSelected = true
        #expect(row.isAccessibilitySelected())

        row.isSelected = false
        row.isSecondarySelected = true
        #expect(row.isAccessibilitySelected())

        row.isSecondarySelected = false
        #expect(!row.isAccessibilitySelected())
    }
}
