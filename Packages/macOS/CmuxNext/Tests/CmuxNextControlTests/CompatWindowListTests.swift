@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `list-windows` lists the windows the user sees, with the workspaces each
/// one's sidebar shows. Before, it also listed windows kept off screen (saved
/// windows whose workspaces no machine reports, Cloud windows waiting for
/// their machine) and printed the total workspace count on every line.
@Suite(.timeLimit(.minutes(1))) struct CompatWindowListTests {
    func install() -> (ControlRouter, CompatService) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        let service = CompatService(frontend: HeadlessCompatFrontend()) { nil }
        service.install(on: router)
        var snapshot = ControlSnapshot.sample()
        snapshot.topology.workspaces.append(ControlWorkspaceInfo(id: "ws-2", handle: "3", name: "Other",
                                                                 screens: [ControlScreenInfo(id: "screen-2", handle: "4")]))
        // win-1 owns ws-1 (shown), ws-2 (another room: not in its sidebar)
        // and ws-gone (no machine reports it).
        var shown = ControlWindowInfo(id: "win-1", workspaceID: "ws-1", workspaceIDs: ["ws-1", "ws-2", "ws-gone"],
                                      isKey: true, isVisible: true, focusedPaneID: "pane-1")
        shown.visibleWorkspaceIDs = ["ws-1"]
        var waiting = ControlWindowInfo(id: "win-2", workspaceID: nil, workspaceIDs: ["ws-cloud"],
                                        isKey: false, isVisible: false, focusedPaneID: nil)
        waiting.isHidden = true
        waiting.visibleWorkspaceIDs = []
        // The hidden window first: it must not take index 0 or the active mark.
        snapshot.topology.windows = [waiting, shown]
        snapshot.topology.focus = ControlFocus(windowID: "win-1", workspaceID: "ws-1", paneID: "pane-1", tabID: "tab-1")
        router.snapshots.publish { $0 = snapshot }
        return (router, service)
    }

    @Test func v1ListWindowsShowsOnlyVisibleWindowsAndTheirSidebarCount() async {
        let (router, _) = install()
        let lines = await router.response(forLine: "list_windows").split(separator: "\n").map(String.init)
        #expect(lines.count == 1, "\(lines)")
        #expect(lines.first?.hasPrefix("* 0: ") == true, "\(lines)")
        #expect(lines.first?.hasSuffix("workspaces=1") == true, "\(lines)")
        let all = await router.response(forLine: "list_windows --all").split(separator: "\n").map(String.init)
        #expect(all.count == 2, "\(all)")
        #expect(all.last?.contains("hidden") == true, "\(all)")
        #expect(all.first?.contains("hidden") == false, "\(all)")
    }

    @Test func v2WindowListHidesHiddenWindowsUnlessAsked() async throws {
        let (router, _) = install()
        let listed = try await router.handle(ControlRequest(method: "window.list")).get()
        let windows = listed["windows"]?.arrayValue ?? []
        #expect(windows.count == 1, "\(listed)")
        #expect(windows.first?["workspace_count"] == 1, "\(listed)")
        #expect(windows.first?["index"] == 0, "\(listed)")
        let all = try await router.handle(ControlRequest(method: "window.list", params: ["include_hidden": true])).get()
        let every = all["windows"]?.arrayValue ?? []
        #expect(every.count == 2, "\(all)")
        #expect(every.contains { $0["hidden"] == true }, "\(all)")
    }
}
