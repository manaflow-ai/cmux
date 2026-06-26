import Testing
@testable import CmuxWorkspaces

/// Verifies the numbered-shortcut mapping preserved from the legacy
/// `WorkspaceShortcutMapper` static helper: digit 9 always targets the last
/// workspace, and the per-row badge uses the lowest matching digit (9 for the
/// last row when no lower digit lands on it).
@Suite
struct WorkspaceShortcutMapperTests {
    @Test
    func commandNineMapsToLastWorkspaceIndex() {
        #expect(WorkspaceShortcutMapper(workspaceCount: 1).workspaceIndex(forDigit: 9) == 0)
        #expect(WorkspaceShortcutMapper(workspaceCount: 4).workspaceIndex(forDigit: 9) == 3)
        #expect(WorkspaceShortcutMapper(workspaceCount: 12).workspaceIndex(forDigit: 9) == 11)
    }

    @Test
    func commandDigitBadgesUseNineForLastWorkspaceWhenNeeded() {
        let mapper = WorkspaceShortcutMapper(workspaceCount: 12)
        #expect(mapper.digitForWorkspace(at: 0) == 1)
        #expect(mapper.digitForWorkspace(at: 7) == 8)
        #expect(mapper.digitForWorkspace(at: 11) == 9)
        #expect(mapper.digitForWorkspace(at: 8) == nil)
    }
}
