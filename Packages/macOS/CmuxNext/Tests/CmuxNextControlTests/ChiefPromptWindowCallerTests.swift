@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// A Chief turn is placed in the window the person prompted it from (#32989): with two windows,
/// each with its own Home, the turn's caller is the prompted window's Home chat, and the
/// workspaces it creates open in that window, not the most recent one.
@Suite(.timeLimit(.minutes(1))) struct ChiefPromptWindowCallerTests {
    /// win-a lists ws-1 and Home A; win-b lists ws-2 and Home B. Each Home has its docked chat.
    static func snapshot(prompted: String?) -> ControlSnapshot {
        var snapshot = BrowserOpenSplitTests.snapshot()
        func home(_ suffix: String) -> ControlWorkspaceInfo {
            var chat = ControlTabInfo(id: "tab-home-\(suffix)", surface: "3\(suffix)", kind: "conversation", title: "Home")
            chat.page = "home-dock"
            var dock = ControlPaneInfo(id: "pane-home-\(suffix)", handle: "8\(suffix)", selectedTabID: chat.id, tabs: [chat])
            dock.column = 0
            dock.dock = "left"
            var workspace = ControlWorkspaceInfo(id: "ws-home-\(suffix)", handle: "10\(suffix)", name: "Home",
                                                 screens: [ControlScreenInfo(id: "screen-home-\(suffix)", handle: "11\(suffix)", panes: [dock])])
            workspace.kind = "home"
            return workspace
        }
        snapshot.topology.workspaces.insert(contentsOf: [home("a"), home("b")], at: 0)
        snapshot.topology.windows = [
            ControlWindowInfo(id: "win-a", workspaceID: "ws-1", workspaceIDs: ["ws-home-a", "ws-1"], isKey: true, isVisible: true, focusedPaneID: "pane-1"),
            ControlWindowInfo(id: "win-b", workspaceID: "ws-2", workspaceIDs: ["ws-home-b", "ws-2"], isKey: false, isVisible: true, focusedPaneID: nil),
        ]
        snapshot.topology.chiefPromptWindowID = prompted
        return snapshot
    }

    func router(prompted: String?, executor: OpenBrowserExecutor = OpenBrowserExecutor()) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { $0 = Self.snapshot(prompted: prompted) }
        executor.router.withLock { $0 = router }
        return router
    }

    @Test func aChiefTurnCreatesInTheWindowItWasPromptedFrom() throws {
        let topology = Self.snapshot(prompted: "win-b").topology
        let window = try ControlCallerWindow(params: ["caller": ["home_chat": true]], in: topology)
        #expect(window?.id == "win-b", "not the first window's: \(String(describing: window))")
    }

    @Test func aChiefTurnNobodyPromptedFromAWindowKeepsTheFirstHomesWindow() throws {
        let topology = Self.snapshot(prompted: nil).topology
        #expect(try ControlCallerWindow(params: ["caller": ["home_chat": true]], in: topology)?.id == "win-a")
    }

    @Test func aTerminalCallerCreatesInTheWindowThatListsItsWorkspace() throws {
        let topology = Self.snapshot(prompted: "win-a").topology
        // term-b is in ws-2, which win-b lists; the prompting window is a Chief's, not this caller's.
        #expect(try ControlCallerWindow(params: ["caller": ["terminal_id": "term-b"]], in: topology)?.id == "win-b")
    }

    @Test func noCallerNamesNoWindow() throws {
        #expect(try ControlCallerWindow(params: [:], in: Self.snapshot(prompted: "win-b").topology) == nil)
    }

    @Test func identifyPlacesAChiefTurnInThePromptedWindowsHome() async throws {
        let reply = try await router(prompted: "win-b").handle(ControlRequest(id: "1", method: "system.identify", params: [
            "caller": ["home_chat": true],
        ])).get()
        #expect(reply["caller"]?["workspace"] == "ws-home-b", "\(String(describing: reply["caller"]))")
        #expect(reply["caller"]?["window"] == "win-b")
    }

    @Test func anActionRunCarriesItsCallersWindow() async throws {
        let executor = OpenBrowserExecutor()
        let router = router(prompted: "win-b", executor: executor)
        _ = try await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "openBrowser", "args": ["url": "https://example.com"], "caller": ["home_chat": true],
        ])).get()
        let request = try #require(executor.all.first)
        #expect(request.callerWindow == "win-b")
    }
}
