import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextLayout
import Foundation
import Testing

/// The right sidebar (inventory row 24): Toggle and Focus Right Sidebar and the Vault, Feed, Dock
/// and Cloud switches run on the active window through the registry (palette, View menu,
/// keyboard, `cmux action run`, MCP). The sidebar sits on the edge opposite the sidebar and the
/// main pane gives it room; the shown section and visibility are remembered for the next window.
/// Files shows the file explorer and Find its project-wide search.
@MainActor @Suite(.serialized)
struct RightSidebarTests {
    static let owned: [ActionID] = ["toggleRightSidebar", "focusRightSidebar", "switchRightSidebarToSessions",
                                    "switchRightSidebarToFeed", "switchRightSidebarToDock", "switchRightSidebarToMachines"]

    private struct Harness {
        let services: AppServices
        let controller: WindowController
        let defaults: UserDefaults
        let suite: String

        func close() {
            for controller in services.windows.controllers { controller.window?.close() }
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let suite = "cmux-right-sidebar-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        services.rightSidebarDefaults = defaults
        services.windows.ordersWindowsIn = false
        AppActions.bind(services)
        let controller = try #require(services.windows.openWindow(workspaces: ["rs-workspace"]))
        return Harness(services: services, controller: controller, defaults: defaults, suite: suite)
    }

    @Test func theRightSidebarActionsAreAvailable() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        for id in Self.owned + ["switchRightSidebarToFiles", "switchRightSidebarToFind"] {
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id) is still greyed out")
        }
    }

    @Test func showFilesShowsTheFileExplorerOfTheFocusedFolder() throws {
        let h = try Self.harness()
        defer { h.close() }
        #expect(h.services.registry.perform("switchRightSidebarToFiles", invocation: ActionInvocation(origin: .cli)))
        let panel = try #require(h.controller.root.rightPanel)
        #expect(panel.shownMode == .files)
        #expect(panel.shownSection is FileExplorerSectionView)
    }

    @Test func toggleShowsTheSidebarBesideAnarrowerContentAndHidesIt() throws {
        let h = try Self.harness()
        defer { h.close() }
        let root = h.controller.root
        root.layoutSubtreeIfNeeded()
        let fullWidth = root.contentHost.frame.width
        #expect(h.services.registry.perform("toggleRightSidebar"))
        root.layoutSubtreeIfNeeded()
        let panel = try #require(root.rightPanel)
        #expect(h.controller.rightSidebar.isVisible)
        #expect(!panel.isHidden && panel.frame.width == RightSidebarModel.width)
        #expect(panel.shownMode == .sessions, "a first show opens the Vault")
        #expect(panel.shownSection is VaultHostView)
        #expect(root.contentHost.frame.width == fullWidth - RightSidebarModel.width, "the main pane makes room")
        #expect(root.contentHost.frame.maxX <= panel.frame.minX, "the panel does not cover the content")
        #expect(h.services.registry.perform("toggleRightSidebar"))
        root.layoutSubtreeIfNeeded()
        #expect(!h.controller.rightSidebar.isVisible && panel.isHidden)
        #expect(root.contentHost.frame.width == fullWidth)
    }

    @Test(arguments: [("switchRightSidebarToSessions", RightSidebarMode.sessions), ("switchRightSidebarToFeed", .feed),
                      ("switchRightSidebarToDock", .dock), ("switchRightSidebarToMachines", .machines)])
    func eachSwitchShowsItsSection(_ id: String, _ mode: RightSidebarMode) throws {
        let h = try Self.harness()
        defer { h.close() }
        #expect(h.services.registry.perform(ActionID(rawValue: id), invocation: ActionInvocation(origin: .cli)))
        let panel = try #require(h.controller.root.rightPanel)
        #expect(h.controller.rightSidebar.isVisible)
        #expect(panel.shownMode == mode)
        #expect(panel.shownSection != nil && panel.shownSection?.isHidden == false)
    }

    @Test func theDockSectionListsTheShownScreensDockedColumns() {
        let model = DockSectionModel()
        let scrolling = LayoutColumn(id: "c1", root: .leaf("p1"))
        let docked = LayoutColumn(id: "c2", root: .leaf("p2"), dock: DockColumn(edge: .left))
        model.update(columns: [scrolling, docked]) { $0 == "p2" ? "notes" : nil }
        #expect(model.rows == [DockSectionRow(id: "c2", edge: .left, pane: "p2", title: "notes")])
    }

    @Test func theLastSectionAndVisibilityCarryToTheNextWindow() throws {
        let h = try Self.harness()
        defer { h.close() }
        #expect(h.services.registry.perform("switchRightSidebarToDock"))
        let next = try #require(h.services.windows.openWindow(workspaces: ["rs-workspace-2"]))
        #expect(next.rightSidebar.isVisible && next.rightSidebar.mode == .dock)
        #expect(next.root.rightPanel?.shownMode == .dock)
    }
}
