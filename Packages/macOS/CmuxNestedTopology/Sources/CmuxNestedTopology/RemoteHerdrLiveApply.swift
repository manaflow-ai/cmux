public import Foundation

/// In-memory Ghostty analogue of ``TerminalSurface`` (manual-mirror I/O).
///
/// AppKit swaps this for a real ``TerminalPanel`` whose
/// ``surface.processRemoteOutput`` receives the same bytes.
public struct RemoteHerdrGhosttySurface: Hashable, Sendable {
    public var paneID: String
    public var surfaceID: String
    public var buffer: [UInt8]
    public var cols: Int
    public var rows: Int
    public var firstResponder: Bool
    public var live: Bool

    public init(
        paneID: String,
        surfaceID: String,
        buffer: [UInt8] = [],
        cols: Int = 80,
        rows: Int = 24,
        firstResponder: Bool = false,
        live: Bool = true
    ) {
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.buffer = buffer
        self.cols = cols
        self.rows = rows
        self.firstResponder = firstResponder
        self.live = live
    }

    /// Append cleaned bytes (tmux ``surface.processRemoteOutput``).
    public mutating func processRemoteOutput(_ data: [UInt8]) {
        guard live, !data.isEmpty else { return }
        buffer.append(contentsOf: data)
    }

    public mutating func resizeGrid(cols: Int, rows: Int) {
        guard cols >= 1, rows >= 1 else { return }
        self.cols = cols
        self.rows = rows
    }
}

/// One live window mirror (tmux ``RemoteTmuxWindowMirror.apply``).
///
/// Isolation: main-actor / single-owner only. `@unchecked Sendable` documents
/// that callers must not share this instance across concurrent executors.
///
/// Runs makePanel *before* rebuild, isolated output, named keys, impose,
/// divider drag, first-responder rules, feed-forward size, seed, cwd.
public final class RemoteHerdrLiveWindow: @unchecked Sendable {
    public var tabID: String
    public var title: String
    public var surfaces: [String: RemoteHerdrGhosttySurface] = [:]
    public var paneIDs: [String] = []
    public var io = RemoteHerdrPaneRoute()
    public var focus = RemoteHerdrFocusController()
    public var seed = RemoteHerdrPaneSeedQueue()
    public var input = RemoteHerdrInputForwarder()
    public var state: RemoteHerdrWindowMirrorState?
    public var hostLog: [String] = []
    public var isApplyingFocus = false
    public var isApplyingLayout = false
    public var isTornDown = false
    public var isVisibleForSizing = true
    public var containerWidth = 800.0
    public var containerHeight = 400.0
    public var cellWidth = 8.0
    public var cellHeight = 16.0
    public var lastClientCols: Int?
    public var lastClientRows: Int?
    public var dragHold: RemoteHerdrDividerDragHold?
    public var tabCwd: String?

    public init(tabID: String, title: String) {
        self.tabID = tabID
        self.title = title
    }

    deinit {}

    /// Create the Ghostty surface *before* the Bonsplit rebuild.
    @discardableResult
    public func makePanel(paneID: String) -> RemoteHerdrGhosttySurface {
        if let existing = surfaces[paneID], existing.live {
            return existing
        }
        let surface = RemoteHerdrGhosttySurface(
            paneID: paneID,
            surfaceID: "surf-\(tabID)-\(paneID)"
        )
        surfaces[paneID] = surface
        if !paneIDs.contains(paneID) {
            paneIDs.append(paneID)
        }
        io.bind(paneID: paneID, surfaceID: surface.surfaceID)
        return surface
    }

    /// Tear down a BASE pane (zoom must not call this).
    public func closePanel(paneID: String) {
        surfaces[paneID]?.live = false
        surfaces.removeValue(forKey: paneID)
        paneIDs.removeAll { $0 == paneID }
        io.unbind(paneID: paneID)
    }

    /// Reconcile + impose + focus. Tmux ``RemoteTmuxWindowMirror.apply``.
    @discardableResult
    public func apply(window: RemoteHerdrWindow) -> [String] {
        guard !isTornDown else { return [] }
        let previous = state
        let previousRendered = previous.map { $0.visibleLayout ?? $0.layout }
        let (next, result) = RemoteHerdrWindowMirror.apply(window: window, previous: previous)
        state = next
        title = RemoteHerdrControl.applySessionTitle(window.title, current: title) ?? window.title
        var log: [String] = []
        if let plan = RemoteHerdrImpose.plan(
            from: result,
            previousRendered: previousRendered,
            title: window.title,
            hold: dragHold
        ) {
            let actions = RemoteHerdrHostApply.actions(result: result, plan: plan)
            isApplyingLayout = true
            defer { isApplyingLayout = false }
            for action in actions {
                log.append(applyHostAction(action))
            }
        } else {
            for paneID in result.createdPaneIDs {
                makePanel(paneID: paneID)
                log.append("make_panel:\(paneID)")
            }
        }
        io.setLivePanes(next.paneIDs)
        focus.livePaneIDs = next.paneIDs
        if let focusPane = result.focusPaneID {
            applyProviderFocus(paneID: focusPane)
        }
        applyCachedCwd()
        hostLog.append(contentsOf: log.filter { !$0.isEmpty })
        return log.filter { !$0.isEmpty }
    }

    private func applyHostAction(_ action: RemoteHerdrHostAction) -> String {
        switch action.op {
        case "create_panel":
            if let paneID = action.paneID {
                makePanel(paneID: paneID)
                return "make_panel:\(paneID)"
            }
        case "close_panel":
            if let paneID = action.paneID {
                closePanel(paneID: paneID)
                return "close_panel:\(paneID)"
            }
        case "focus":
            return ""
        default:
            break
        }
        return action.op
    }

    /// ``%output`` → exactly one surface. Unknown pane is a no-op.
    @discardableResult
    public func routeOutput(paneID: String, data: [UInt8]) -> Bool {
        guard let write = io.routeOutput(paneID: paneID, data: Data(data)) else {
            return false
        }
        guard var surface = surfaces[paneID], surface.live else { return false }
        surface.processRemoteOutput(Array(write.data))
        surfaces[paneID] = surface
        return true
    }

    public func sendText(paneID: String, text: String) -> String {
        guard io.routeInput(paneID: paneID, data: Data(text.utf8)) != nil else {
            return "inactive"
        }
        let item = RemoteHerdrProviderInput(paneID: paneID, kind: "text", text: text)
        return input.enqueue(item)
    }

    public func sendNamedKey(paneID: String, name: String) -> String {
        guard let item = RemoteHerdrControl.encodeNamedKey(paneID: paneID, rawName: name) else {
            return "unknown"
        }
        guard surfaces[paneID] != nil else { return "inactive" }
        return input.enqueue(item)
    }

    /// Provider focus: project locally, never steal first responder.
    public func applyProviderFocus(paneID: String) {
        isApplyingFocus = true
        defer { isApplyingFocus = false }
        _ = focus.providerConfirms(paneID)
        _ = io.noteRemoteActive(paneID: paneID)
        applyCachedCwd()
    }

    /// User click may take first responder; provider path must not.
    @discardableResult
    public func userFocus(paneID: String) -> Bool {
        guard surfaces[paneID] != nil, !isApplyingFocus else { return false }
        _ = focus.userSelect(paneID)
        _ = io.userFocus(paneID: paneID)
        for key in surfaces.keys {
            guard var surface = surfaces[key] else { continue }
            surface.firstResponder = (key == paneID)
            surfaces[key] = surface
        }
        applyCachedCwd()
        return true
    }

    @discardableResult
    public func navigateFocus(direction: String) -> String? {
        guard let layout = state?.visibleLayout ?? state?.layout,
              let active = focus.activePaneID else { return nil }
        guard let neighbor = RemoteHerdrControl.adjacentPane(
            layout,
            paneID: active,
            direction: direction
        ) else { return nil }
        return userFocus(paneID: neighbor) ? neighbor : nil
    }

    public func userSplit(paneID: String, direction: String) -> RemoteHerdrUserSplit? {
        guard surfaces[paneID] != nil else { return nil }
        let vertical = ["down", "vertical", "below"].contains(direction)
        return RemoteHerdrControl.requestSplit(fromPaneID: paneID, vertical: vertical)
    }

    /// Feed-forward claim. Never reads a measured pane frame.
    @discardableResult
    public func updateClientSize() -> (Int, Int)? {
        guard isVisibleForSizing, !isTornDown else { return nil }
        let grid = RemoteHerdrSizing().clientGrid(
            contentWidth: containerWidth,
            contentHeight: containerHeight,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
        guard let grid else { return nil }
        if lastClientCols == grid.cols, lastClientRows == grid.rows {
            return (grid.cols, grid.rows)
        }
        lastClientCols = grid.cols
        lastClientRows = grid.rows
        for key in surfaces.keys {
            guard var surface = surfaces[key], surface.live else { continue }
            surface.resizeGrid(cols: grid.cols, rows: grid.rows)
            surfaces[key] = surface
        }
        // Flush seeds that were waiting for this client grid.
        for key in surfaces.keys {
            if let flushed = seed.noteReady(paneID: key, cols: grid.cols, rows: grid.rows) {
                _ = routeOutput(paneID: key, data: Array(flushed))
            }
        }
        return (grid.cols, grid.rows)
    }

    public func beginDrag(splitKey: String, axis: RemoteHerdrSplitOrientation, assignedCells: Int) {
        dragHold = RemoteHerdrImpose.beginDividerDrag(
            splitKey: splitKey,
            axis: axis,
            assignedCells: assignedCells
        )
    }

    public func endDrag(
        draggedExtent: Double,
        axisSpan: Double,
        totalCells: Int,
        assignedCells: Int
    ) -> (cells: Int, shouldSend: Bool) {
        let result = RemoteHerdrImpose.endDividerDrag(
            draggedExtent: draggedExtent,
            axisSpan: axisSpan,
            totalCells: totalCells,
            assignedCells: assignedCells
        )
        if result.shouldSend {
            dragHold = RemoteHerdrImpose.beginDividerDrag(
                splitKey: dragHold?.splitKey ?? "s",
                axis: dragHold?.axis ?? .horizontal,
                assignedCells: result.cells
            )
        } else {
            dragHold = nil
        }
        return result
    }

    public func noteResizeReply(assignedCells: Int, splitExists: Bool = true) {
        dragHold = RemoteHerdrImpose.resolveDividerHold(
            dragHold,
            assignedCells: assignedCells,
            splitStillExists: splitExists
        )
    }

    @discardableResult
    public func seedPane(paneID: String, data: Data, cols: Int, rows: Int) -> Data? {
        _ = seed.queue(paneID: paneID, data: data, kind: "full", targetGrid: (cols, rows))
        let current = surfaces[paneID].map { ($0.cols, $0.rows) } ?? (0, 0)
        guard let flushed = seed.noteReady(paneID: paneID, cols: current.0, rows: current.1) else {
            return nil
        }
        _ = routeOutput(paneID: paneID, data: Array(flushed))
        return flushed
    }

    /// Cache cwd; apply to the tab only when this pane is active.
    @discardableResult
    public func routeCwd(paneID: String, path: String) -> RemoteHerdrCwdUpdate? {
        let update = io.routeCwd(paneID: paneID, path: path, tabID: tabID)
        if let update, update.applyToTab {
            tabCwd = update.path
        }
        return update
    }

    private func applyCachedCwd() {
        let active = io.activePaneID ?? focus.activePaneID
        guard let active, let path = io.cwdByPane[active] else { return }
        tabCwd = path
    }

    public func teardown() {
        isTornDown = true
        input.deactivate()
        for key in surfaces.keys {
            guard var surface = surfaces[key] else { continue }
            surface.live = false
            surface.firstResponder = false
            surfaces[key] = surface
        }
    }

    public func paneGrids() -> [String: Any] {
        let layout = state?.visibleLayout ?? state?.layout
        var panes: [[String: Any]] = []
        for paneID in surfaces.keys.sorted() {
            guard let surface = surfaces[paneID] else { continue }
            var assignedCols = surface.cols
            var assignedRows = surface.rows
            if let leaf = layout?.firstLeaf(withPaneID: paneID) {
                assignedCols = max(1, leaf.width)
                assignedRows = max(1, leaf.height)
            }
            let axis = layout?.exactAxisFlags(forPaneID: paneID) ?? (false, false)
            panes.append([
                "pane_id": paneID,
                "assigned_cols": assignedCols,
                "assigned_rows": assignedRows,
                "rendered_cols": surface.cols,
                "rendered_rows": surface.rows,
                "exact_cols": axis.exactCols,
                "exact_rows": axis.exactRows,
                "has_panel": surface.live,
            ])
        }
        return [
            "tab_id": tabID,
            "panes": panes,
            "structure_version": state?.layoutStructureVersion ?? 0,
            "zoomed": state?.zoomed ?? false,
            "visible_for_sizing": isVisibleForSizing,
        ]
    }
}

/// Session-level live machine (tmux ``RemoteTmuxSessionMirror`` + controller).
///
/// Isolation: main-actor / single-owner only (same as ``RemoteHerdrLiveWindow``).
public final class RemoteHerdrLiveHost: @unchecked Sendable {
    public var enabled: Bool
    public var socketPath: String
    public var windows: [String: RemoteHerdrLiveWindow] = [:]
    public var previousTabIDs: [String] = []
    public var previousTitles: [String: String] = [:]
    public var defaultsOpen = true
    public var sessionOps: [String] = []
    public var agentStatuses: [String: String] = [:]
    public var agentNames: [String: String] = [:]
    public var nativeLive = false
    public var serverStopped = false
    public var log: [String] = []

    public init(enabled: Bool = true, socketPath: String = "/tmp/herdr.sock") {
        self.enabled = enabled
        self.socketPath = socketPath
    }

    deinit {}

    /// Create/close tabs, then apply each window mirror.
    @discardableResult
    public func applySession(_ windows: [RemoteHerdrWindow]) -> [String: Any] {
        guard enabled else { return ["ok": false, "outcome": "disabled"] }
        let session = RemoteHerdrSessionMirror.reconcile(
            windows: windows,
            previousTabIDs: previousTabIDs
        )
        let titles = RemoteHerdrSessionApply.titlesByTabID(windows)
        let actions = RemoteHerdrSessionApply.actions(
            session,
            titles: titles,
            previousTitles: previousTitles,
            defaultsOpen: defaultsOpen
        )
        sessionOps = actions.map(\.op)
        if actions.contains(where: { $0.op == "close_default_tabs" }) {
            defaultsOpen = false
        }
        for tabID in session.closedTabIDs {
            self.windows.removeValue(forKey: tabID)?.teardown()
        }
        var applied: [String] = []
        for window in windows {
            let mirror = self.windows[window.tabID] ?? RemoteHerdrLiveWindow(
                tabID: window.tabID,
                title: window.title
            )
            applied.append(contentsOf: mirror.apply(window: window))
            _ = mirror.updateClientSize()
            self.windows[window.tabID] = mirror
        }
        previousTabIDs = session.orderedTabIDs
        previousTitles = titles
        log.append("session:tabs=\(self.windows.count)")
        return [
            "ok": true,
            "tabs": Array(self.windows.keys),
            "session_ops": sessionOps,
            "window_ops": applied,
            "defaults_open": defaultsOpen,
        ]
    }

    @discardableResult
    public func attach(
        sessions: [RemoteHerdrDiscoveredSession],
        activate: Bool = true,
        activeWindowID: String? = nil,
        liveWindows: [String] = []
    ) -> [String: Any] {
        guard enabled else { return ["ok": false, "outcome": "disabled"] }
        let plan = RemoteHerdrAttachPlanner.plan(
            target: RemoteHerdrAttachWindowTarget(kind: "contextual"),
            enabled: enabled,
            appReady: true,
            alreadyAttaching: false,
            existingMirrorWindowID: nil,
            activeWindowID: activeWindowID,
            liveWindows: liveWindows,
            sessions: sessions,
            activate: activate
        )
        if plan.postAttach == RemoteHerdrLifecycle.postApplyClientSize {
            for window in windows.values {
                _ = window.updateClientSize()
            }
        }
        if plan.postAttach == RemoteHerdrLifecycle.postReseed {
            for window in windows.values {
                for (paneID, surface) in window.surfaces {
                    _ = window.seedPane(
                        paneID: paneID,
                        data: Data(surface.buffer),
                        cols: surface.cols,
                        rows: surface.rows
                    )
                }
            }
        }
        log.append("attach:\(plan.outcome)")
        return [
            "ok": plan.outcome == "mirrored" || plan.outcome == "reused",
            "outcome": plan.outcome,
            "window_id": plan.windowID as Any,
            "post_attach": plan.postAttach as Any,
        ]
    }

    @discardableResult
    public func routeOutput(paneID: String, data: [UInt8]) -> Bool {
        for window in windows.values where window.surfaces[paneID] != nil {
            return window.routeOutput(paneID: paneID, data: data)
        }
        return false
    }

    @discardableResult
    public func routeCwd(paneID: String, path: String) -> RemoteHerdrCwdUpdate? {
        for window in windows.values where window.surfaces[paneID] != nil {
            return window.routeCwd(paneID: paneID, path: path)
        }
        return nil
    }

    /// Host close: teardown every mirror, never ``server.stop``.
    @discardableResult
    public func detach() -> [String: Any] {
        for window in windows.values {
            window.teardown()
        }
        windows.removeAll()
        nativeLive = false
        serverStopped = false
        log.append("detach")
        return [
            "ok": true,
            "outcome": "detach",
            "server_stopped": false,
            "policy": RemoteHerdrLifecycle.hostClosePolicy("host_tab"),
        ]
    }

    /// Restore after cmux restart: reattach, never replay a stale tree.
    @discardableResult
    public func restore(
        sessions: [RemoteHerdrDiscoveredSession],
        windows: [RemoteHerdrWindow],
        activeWindowID: String? = nil,
        liveWindows: [String] = []
    ) -> [String: Any] {
        let record = RemoteHerdrRestoreRecord(
            endpointHash: RemoteHerdrLifecycle.endpointHash(socketPath),
            socketPath: socketPath,
            sessionIDs: sessions.map(\.sessionID),
            targetKind: "contextual"
        )
        let plan = RemoteHerdrAttachPlanner.planRestore(
            record,
            enabled: enabled,
            appReady: true,
            sessions: sessions,
            liveWindows: liveWindows,
            activeWindowID: activeWindowID
        )
        let accepted = plan.outcome == "mirrored" || plan.outcome == "reused"
        guard accepted else {
            return [
                "ok": false,
                "outcome": plan.outcome,
                "window_id": plan.windowID as Any,
                "reason": plan.reason as Any,
                "mode": "reattach",
            ]
        }
        let applied = applySession(windows)
        for window in self.windows.values {
            for (paneID, surface) in window.surfaces {
                _ = window.seedPane(
                    paneID: paneID,
                    data: Data(surface.buffer),
                    cols: surface.cols,
                    rows: surface.rows
                )
            }
        }
        return [
            "ok": (plan.outcome == "mirrored" || plan.outcome == "reused")
                && (applied["ok"] as? Bool == true),
            "mode": "reattach",
            "window_id": plan.windowID as Any,
            "post_attach": RemoteHerdrLifecycle.postReseed,
        ]
    }

    public func setNativeLive() {
        nativeLive = true
        log.append("native_live")
    }

    public func closeUserPane(paneID: String) -> RemoteHerdrCloseIntent {
        RemoteHerdrControl.closeIntent(
            source: "user_pane",
            paneID: paneID,
            agentStatus: agentStatuses[paneID]
        )
    }

    public func activity() -> RemoteHerdrTabActivity {
        RemoteHerdrControl.tabActivity(statuses: agentStatuses, agents: agentNames)
    }

    public func paneSurfaces() -> [[String: Any]] {
        var rows: [(String, String, String, Bool)] = []
        for (tabID, window) in windows {
            for (paneID, surface) in window.surfaces {
                rows.append((tabID, paneID, surface.surfaceID, surface.live && !window.isTornDown))
            }
        }
        return RemoteHerdrControl.paneSurfaceEntries(rows)
    }

    public func observe(method: String, params: [String: Any] = [:]) -> [String: Any] {
        var merged = params
        if merged["socket"] == nil {
            merged["socket"] = socketPath
        }
        var gate = RemoteHerdrAttachPlanner.dispatch(
            method: method,
            params: merged,
            enabled: enabled
        )
        guard gate["ok"] as? Bool == true else { return gate }
        switch method {
        case "remote.herdr.pane_surfaces":
            gate["panes"] = paneSurfaces()
            gate["mirrored"] = !windows.isEmpty
        case "remote.herdr.pane_grids":
            gate["windows"] = windows.values.map { $0.paneGrids() }
            gate["mirrored"] = !windows.isEmpty
        case "remote.herdr.state":
            gate["window_count"] = windows.count
            gate["window_ids"] = Array(windows.keys)
        case "remote.herdr.detach":
            gate.merge(detach()) { _, new in new }
        default:
            break
        }
        return gate
    }
}
