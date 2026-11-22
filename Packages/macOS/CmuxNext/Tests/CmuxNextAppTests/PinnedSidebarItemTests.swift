import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// Pinned tabs, pages and spaces in sidebar sections act in the window
/// whose sidebar was clicked (plans/cmux-next/sidebar-sections.md 2): a
/// tab selects its workspace and the tab, a page focuses a tab of the
/// current space already showing it, and a space shows in the window.
/// Windows are never put on screen.
@MainActor
struct PinnedSidebarItemTests {
    static let keys = (1...3).map { WorkspaceKey(rawValue: "5b2d7c1e-8f3a-4e6b-9c0d-1a2b3c4d5e6\($0)") }
    nonisolated static let session = "22222222-3333-4444-8555-666666666666"
    static let work: ProfileID = "prof_work"

    private static func id(_ index: Int) -> String { keys[index - 1].rawValue }

    /// w1 holds a terminal; w2 a docs page; w3, pinned to Work, a page
    /// open only there. Default follows this session.
    private static func services() -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let tabs: [[TabSnapshot]] = [
            [TabSnapshot(surface: 11, tabResourceID: "tab_shell", title: "zsh")],
            [TabSnapshot(surface: 21, tabResourceID: "tab_docs", kind: .browser, title: "Docs", url: "https://example.com/docs/")],
            [TabSnapshot(surface: 31, tabResourceID: "tab_board", kind: .browser, title: "Board", url: "https://example.com/board")],
        ]
        let snapshots = keys.enumerated().map { index, key in
            let pane = PaneID(rawValue: UInt64(index + 1) * 10)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(index + 1) * 100), layout: .leaf(pane),
                                        panes: [PaneSnapshot(id: pane, resourceID: ResourceID(rawValue: "pane_\(index + 1)"), tabs: tabs[index])])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: key, name: "w\(index + 1)", screens: [screen])
        }
        var tree = DaemonTree(registryID: session, workspaceRevision: 100, workspaces: snapshots)
        tree.personal = PersonalState(
            revision: 1,
            profiles: [ProfileSnapshot(id: .defaultProfile, name: "default", index: 0, follows: [session]),
                       ProfileSnapshot(id: work, name: "Work", index: 1, follows: [])],
            pins: [WorkspacePin(sessionID: session, workspaceKey: keys[2], profile: work)])
        services.daemon.store.apply(snapshot: tree)
        return services
    }

    private static func window(_ services: AppServices) throws -> WindowController {
        let window = try #require(services.windows.openWindow(workspaces: keys.map(\.rawValue)))
        services.windows.select(id(1), in: window.state)
        return window
    }

    @Test func aPinnedSpaceShowsInTheWindow() throws {
        let services = Self.services()
        let window = try Self.window(services)
        window.sidebar.activate(.room("prof_missing"))
        #expect(window.state.profileID == .defaultProfile)
        window.sidebar.activate(.room(Self.work.rawValue))
        #expect(window.state.profileID == Self.work)
        #expect(window.state.workspaceID == Self.id(3))
        window.window?.close()
    }

    @Test(arguments: ["tab_docs", "\(session):tab_docs"])
    func aPinnedTabSelectsItsWorkspaceAndTheTab(_ ref: String) throws {
        let services = Self.services()
        let window = try Self.window(services)
        window.sidebar.activate(.tab(ref))
        #expect(window.state.workspaceID == Self.id(2))
        #expect(window.state.selection.selection(in: "pane_2") == "tab_docs")
        window.window?.close()
    }

    @Test func aPinnedTabListedByAnotherWindowIsSelectedThere() throws {
        let services = Self.services()
        let here = try #require(services.windows.openWindow(workspaces: [Self.id(1), Self.id(3)]))
        let there = try #require(services.windows.openWindow(workspaces: [Self.id(2)]))
        here.sidebar.activate(.tab("tab_docs"))
        #expect(there.state.workspaceID == Self.id(2))
        #expect(there.state.selection.selection(in: "pane_2") == "tab_docs")
        #expect(here.state.selection.selection(in: "pane_2") == nil)
        #expect(here.state.workspaceID != Self.id(2))
        here.window?.close()
        there.window?.close()
    }

    @Test func aPinnedPageThatIsNotHTTPDoesNothing() throws {
        let services = Self.services()
        let window = try Self.window(services)
        window.sidebar.activate(.url("javascript:alert(1)"))
        window.sidebar.activate(.url("file:///etc/hosts"))
        #expect(window.state.workspaceID == Self.id(1))
        window.window?.close()
    }

    @Test func aPinnedTabOfAnotherSessionIsNotGuessed() throws {
        let services = Self.services()
        let window = try Self.window(services)
        window.sidebar.activate(.tab("33333333-0000-4000-8000-000000000000:tab_docs"))
        #expect(window.state.workspaceID == Self.id(1))
        window.window?.close()
    }

    @Test func aPinnedPageFocusesTheTabAlreadyShowingIt() throws {
        let services = Self.services()
        let window = try Self.window(services)
        window.sidebar.activate(.url("https://EXAMPLE.com/docs#intro"))
        #expect(window.state.workspaceID == Self.id(2))
        #expect(window.state.selection.selection(in: "pane_2") == "tab_docs")
        window.window?.close()
    }

    @Test func aPinnedPageOpenOnlyInAnotherSpaceIsNotFocusedThere() throws {
        let services = Self.services()
        let window = try Self.window(services)
        window.sidebar.activate(.url("https://example.com/board"))
        #expect(window.state.profileID == .defaultProfile)
        #expect(window.state.workspaceID == Self.id(1))
        #expect(window.state.selection.selection(in: "pane_3") == nil)
        window.window?.close()
    }

    @Test func samePageIgnoresCaseOfTheHostATrailingSlashAndTheFragment() {
        func same(_ a: String, _ b: String) -> Bool { SidebarBridge.samePage(URL(string: a)!, URL(string: b)!) }
        #expect(same("https://Example.com/a/#x", "https://example.com/a"))
        #expect(same("https://example.com", "https://example.com/"))
        #expect(!same("https://example.com/a?q=1", "https://example.com/a?q=2"))
        #expect(!same("https://example.com/a", "https://example.com/A"))
        #expect(!same("http://example.com/a", "https://example.com/a"))
    }
}
