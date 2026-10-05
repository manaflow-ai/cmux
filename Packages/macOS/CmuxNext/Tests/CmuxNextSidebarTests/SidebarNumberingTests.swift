@testable import CmuxNextSidebar
import Testing

/// R119: Cmd+1…9 numbers Home first, then the workspaces in sidebar order;
/// Cmd+9 is the last. Home is never numbered twice, and with no Home yet
/// the workspaces start at 1.
struct SidebarNumberingTests {
    @Test func homeIsOneThenWorkspacesInOrder() {
        let order = SidebarNumbering.order(home: "home", workspaces: ["a", "b", "c"])
        #expect(order == ["home", "a", "b", "c"])
        #expect(SidebarNumbering.pick(1, home: "home", workspaces: ["a", "b", "c"]) == "home")
        #expect(SidebarNumbering.pick(2, home: "home", workspaces: ["a", "b", "c"]) == "a")
        #expect(SidebarNumbering.pick(4, home: "home", workspaces: ["a", "b", "c"]) == "c")
    }

    @Test func nineIsLastAndPastTheEndClamps() {
        #expect(SidebarNumbering.pick(9, home: "home", workspaces: ["a", "b"]) == "b")
        #expect(SidebarNumbering.pick(6, home: "home", workspaces: ["a", "b"]) == "b")
        #expect(SidebarNumbering.pick(9, home: "home", workspaces: []) == "home")
    }

    @Test func homeListedAmongWorkspacesIsNotNumberedTwice() {
        #expect(SidebarNumbering.order(home: "home", workspaces: ["a", "home", "b"]) == ["home", "a", "b"])
    }

    @Test func noHomeStartsAtTheFirstWorkspace() {
        #expect(SidebarNumbering.pick(1, home: nil, workspaces: ["a", "b"]) == "a")
        #expect(SidebarNumbering.pick(1, home: nil, workspaces: []) == nil)
        #expect(SidebarNumbering.pick(0, home: "home", workspaces: ["a"]) == nil)
    }
}
