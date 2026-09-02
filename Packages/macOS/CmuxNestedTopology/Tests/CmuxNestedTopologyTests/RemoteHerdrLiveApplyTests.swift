import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct RemoteHerdrLiveApplyTests {
    private func window(
        tabID: String = "w2:t1",
        title: String = "Build",
        active: String? = "p1",
        zoomed: Bool = false
    ) -> RemoteHerdrWindow {
        let left = RemoteHerdrLayoutNode(width: 100, height: 50, x: 0, y: 0, content: .pane("p1"))
        let right = RemoteHerdrLayoutNode(width: 99, height: 50, x: 101, y: 0, content: .pane("p2"))
        let layout = RemoteHerdrLayoutNode(
            width: 200,
            height: 50,
            x: 0,
            y: 0,
            content: .horizontal([left, right])
        )
        return RemoteHerdrWindow(
            tabID: tabID,
            title: title,
            orderIndex: 0,
            layout: layout,
            visibleLayout: zoomed ? left : nil,
            zoomed: zoomed,
            activePaneID: active
        )
    }

    @Test func makePanelThenOutputStaysIsolated() {
        let host = RemoteHerdrLiveHost()
        _ = host.applySession([window()])
        #expect(host.windows["w2:t1"]?.surfaces["p1"] != nil)
        #expect(host.windows["w2:t1"]?.routeOutput(paneID: "p1", data: Array("hello".utf8)) == true)
        #expect(host.windows["w2:t1"]?.surfaces["p1"]?.buffer == Array("hello".utf8))
        #expect(host.windows["w2:t1"]?.surfaces["p2"]?.buffer.isEmpty == true)
        #expect(host.windows["w2:t1"]?.routeOutput(paneID: "missing", data: [1]) == false)
        #expect(host.windows["w2:t1"]?.hostLog.contains(where: { $0.hasPrefix("make_panel:") }) == true)
    }

    @Test func titleEscapeIsStrippedBeforeGhostty() {
        let host = RemoteHerdrLiveHost()
        _ = host.applySession([window()])
        _ = host.windows["w2:t1"]?.routeOutput(
            paneID: "p1",
            data: [0x61, 0x62, 0x1b, 0x6b, 0x54, 0x1b, 0x5c, 0x63, 0x64]
        )
        #expect(host.windows["w2:t1"]?.surfaces["p1"]?.buffer == [0x61, 0x62, 0x63, 0x64])
    }

    @Test func providerFocusDoesNotStealFirstResponder() {
        let host = RemoteHerdrLiveHost()
        _ = host.applySession([window()])
        #expect(host.windows["w2:t1"]?.userFocus(paneID: "p1") == true)
        #expect(host.windows["w2:t1"]?.surfaces["p1"]?.firstResponder == true)
        host.windows["w2:t1"]?.applyProviderFocus(paneID: "p2")
        #expect(host.windows["w2:t1"]?.isApplyingFocus == false)
        #expect(host.windows["w2:t1"]?.surfaces["p1"]?.firstResponder == true)
        #expect(host.windows["w2:t1"]?.surfaces["p2"]?.firstResponder == false)
    }

    @Test func namedKeyAndAdjacentFocus() {
        let host = RemoteHerdrLiveHost()
        _ = host.applySession([window()])
        let mirror = host.windows["w2:t1"]
        #expect(mirror?.sendNamedKey(paneID: "p1", name: "C-Up") == "enqueued")
        #expect(mirror?.sendNamedKey(paneID: "p1", name: "NotAKey") == "unknown")
        _ = mirror?.userFocus(paneID: "p1")
        #expect(mirror?.navigateFocus(direction: "right") == "p2")
        #expect(mirror?.userSplit(paneID: "p1", direction: "down")?.orientation == "vertical")
    }

    @Test func clientSizeIgnoresPaneFrames() {
        let host = RemoteHerdrLiveHost()
        _ = host.applySession([window()])
        host.windows["w2:t1"]?.containerWidth = 160
        host.windows["w2:t1"]?.containerHeight = 48
        host.windows["w2:t1"]?.lastClientCols = nil
        let grid = host.windows["w2:t1"]?.updateClientSize()
        #expect(grid?.0 == 20)
        #expect(grid?.1 == 3)
        host.windows["w2:t1"]?.surfaces["p1"]?.cols = 999
        let again = host.windows["w2:t1"]?.updateClientSize()
        #expect(again?.0 == 20)
        #expect(host.windows["w2:t1"]?.lastClientCols == 20)
    }

    @Test func dividerDragSendsOnlyWhenCellsChange() {
        let host = RemoteHerdrLiveHost()
        _ = host.applySession([window()])
        host.windows["w2:t1"]?.beginDrag(splitKey: "s", axis: .horizontal, assignedCells: 100)
        let sent = host.windows["w2:t1"]?.endDrag(
            draggedExtent: 50, axisSpan: 200, totalCells: 200, assignedCells: 100
        )
        #expect(sent?.shouldSend == true)
        #expect(sent?.cells == 50)
        let noop = host.windows["w2:t1"]?.endDrag(
            draggedExtent: 100, axisSpan: 200, totalCells: 200, assignedCells: 100
        )
        #expect(noop?.shouldSend == false)
    }

    @Test func backgroundCdDoesNotHijackTabFolder() {
        let host = RemoteHerdrLiveHost()
        _ = host.applySession([window(active: "p1")])
        let background = host.routeCwd(paneID: "p2", path: "/tmp/other")
        #expect(background?.applyToTab == false)
        #expect(host.windows["w2:t1"]?.tabCwd == nil)
        let active = host.routeCwd(paneID: "p1", path: "/tmp/here")
        #expect(active?.applyToTab == true)
        #expect(host.windows["w2:t1"]?.tabCwd == "/tmp/here")
        _ = host.windows["w2:t1"]?.userFocus(paneID: "p2")
        #expect(host.windows["w2:t1"]?.tabCwd == "/tmp/other")
    }

    @Test func detachNeverStopsServer() {
        let host = RemoteHerdrLiveHost()
        _ = host.applySession([window()])
        host.setNativeLive()
        let closed = host.detach()
        #expect(host.windows.isEmpty)
        #expect(host.serverStopped == false)
        #expect(host.nativeLive == false)
        #expect(closed["outcome"] as? String == "detach")
    }

    @Test func zoomMustNotCloseHiddenPanel() {
        let host = RemoteHerdrLiveHost()
        _ = host.applySession([window()])
        _ = host.applySession([window(active: "p1", zoomed: true)])
        #expect(host.windows["w2:t1"]?.surfaces["p2"]?.live == true)
    }

    @Test func restoreReattaches() {
        let host = RemoteHerdrLiveHost()
        _ = host.applySession([window()])
        let result = host.restore(
            sessions: [RemoteHerdrDiscoveredSession(sessionID: "sess-1", name: "main")],
            windows: [window()],
            activeWindowID: "win-restore",
            liveWindows: ["win-restore"]
        )
        #expect(result["mode"] as? String == "reattach")
        #expect(result["post_attach"] as? String == RemoteHerdrLifecycle.postReseed)
        #expect(host.windows["w2:t1"] != nil)
        #expect(result["window_id"] as? String == "win-restore")
        #expect(result["window_id"] as? String != "w1")
    }

    @Test func restoreRejectedPlanDoesNotApplyWindows() {
        let host = RemoteHerdrLiveHost()
        let result = host.restore(
            sessions: [RemoteHerdrDiscoveredSession(sessionID: "sess-1", name: "main")],
            windows: [window(tabID: "should-not-apply")],
            activeWindowID: "win-dead",
            liveWindows: []
        )
        #expect(result["ok"] as? Bool == false)
        #expect(host.windows["should-not-apply"] == nil)
        #expect(host.windows.isEmpty)
    }

    @Test func duplicateTabIDsLastTitleWinsWithoutTrapping() {
        let host = RemoteHerdrLiveHost()
        let result = host.applySession([
            window(tabID: "dup", title: "First"),
            window(tabID: "dup", title: "Last"),
        ])
        #expect(result["ok"] as? Bool == true)
        #expect(host.windows["dup"]?.title == "Last")
        #expect(host.previousTitles["dup"] == "Last")
        #expect(host.windows.count == 1)
        #expect(RemoteHerdrSessionApply.titlesByTabID([
            window(tabID: "dup", title: "First"),
            window(tabID: "dup", title: "Last"),
        ])["dup"] == "Last")
    }

    @Test func attachUsesProvidedLiveWindowIdentity() {
        let host = RemoteHerdrLiveHost()
        let result = host.attach(
            sessions: [RemoteHerdrDiscoveredSession(sessionID: "sess-1", name: "main")],
            activeWindowID: "win-live",
            liveWindows: ["win-live", "win-other"]
        )
        #expect(result["ok"] as? Bool == true)
        #expect(result["outcome"] as? String == "mirrored")
        #expect(result["window_id"] as? String == "win-live")
        #expect(result["window_id"] as? String != "w1")
    }

    @Test func busyCloseAndObserve() {
        let host = RemoteHerdrLiveHost()
        _ = host.applySession([window()])
        host.agentStatuses = ["p1": "working"]
        host.agentNames = ["p1": "coder"]
        #expect(host.closeUserPane(paneID: "p1").action == "confirm_then_close_pane")
        #expect(host.activity().hasActiveCommand)
        let surfaces = host.observe(
            method: "remote.herdr.pane_surfaces",
            params: ["socket": "/tmp/herdr.sock", "session": "main"]
        )
        #expect(surfaces["ok"] as? Bool == true)
        #expect((surfaces["panes"] as? [[String: Any]])?.count == 2)
    }

    @Test func seedWaitsForGrid() {
        let mirror = RemoteHerdrLiveWindow(tabID: "t", title: "t")
        mirror.makePanel(paneID: "p")
        mirror.surfaces["p"]?.resizeGrid(cols: 40, rows: 12)
        #expect(mirror.seedPane(paneID: "p", data: Data("hello".utf8), cols: 80, rows: 24) == nil)
        #expect(mirror.seed.noteReady(paneID: "p", cols: 80, rows: 24) == Data("hello".utf8))
    }
}

@Suite struct RemoteHerdrControlTests {
    @Test func namedKeyFailsClosed() {
        #expect(RemoteHerdrControl.encodeNamedKey(paneID: "p", rawName: "C-Up")?.key == "C-Up")
        #expect(RemoteHerdrControl.encodeNamedKey(paneID: "p", rawName: "Nope") == nil)
    }

    @Test func focusRollbackRestoresPrevious() {
        let focus = RemoteHerdrFocusController()
        focus.livePaneIDs = ["p1", "p2"]
        focus.activePaneID = "p1"
        let command = focus.userSelect("p2")
        #expect(command.sendToProvider)
        #expect(focus.activePaneID == "p2")
        let rolled = focus.commandRejected(command.requestID ?? "")
        #expect(rolled.rolledBack)
        #expect(focus.activePaneID == "p1")
    }
}
