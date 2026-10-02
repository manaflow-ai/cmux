import CmuxNextSidebar
import Testing

struct SidebarNumberingTests {
    let ids = (1...12).map { WorkspaceID("w\($0)") }

    @Test func oneIsHomeAndTheRestShiftByOne() {
        #expect(SidebarNumbering.target(digit: 1, workspaces: ids) == .home)
        #expect(SidebarNumbering.target(digit: 2, workspaces: ids) == .workspace(WorkspaceID("w1")))
        #expect(SidebarNumbering.target(digit: 8, workspaces: ids) == .workspace(WorkspaceID("w7")))
        #expect(SidebarNumbering.target(digit: 9, workspaces: ids) == .workspace(WorkspaceID("w12")))
    }

    @Test func shortListsClampToTheLastWorkspace() {
        let two = Array(ids.prefix(2))
        #expect(SidebarNumbering.target(digit: 5, workspaces: two) == .workspace(WorkspaceID("w2")))
        #expect(SidebarNumbering.target(digit: 9, workspaces: two) == .workspace(WorkspaceID("w2")))
    }

    @Test func homeNeedsNoWorkspaceAndOtherDigitsDo() {
        #expect(SidebarNumbering.target(digit: 1, workspaces: []) == .home)
        #expect(SidebarNumbering.target(digit: 2, workspaces: []) == nil)
        #expect(SidebarNumbering.target(digit: 0, workspaces: ids) == nil)
        #expect(SidebarNumbering.target(digit: 10, workspaces: ids) == nil)
    }
}
