import AppKit
import Bonsplit
import CmuxTerminal
import Foundation
import Observation

@MainActor
@Observable
final class RemoteTmuxWindowMirror {
    let windowId: Int
    let panelId: UUID
    var bonsplitController: BonsplitController
    private(set) var layout: RemoteTmuxLayoutNode
    private(set) var activePaneId: Int?

    @ObservationIgnored weak var connection: RemoteTmuxControlConnection?
    @ObservationIgnored let makePanel: (_ tmuxPaneId: Int) -> TerminalPanel?
    @ObservationIgnored var onClosePaneRequest: ((Int) -> Void)?
    @ObservationIgnored var panelsByPaneId: [Int: TerminalPanel] = [:]
    @ObservationIgnored var tabIdByPaneId: [Int: TabID] = [:]
    @ObservationIgnored var paneIdByPaneId: [Int: PaneID] = [:]
    @ObservationIgnored var paneIdByBonsplitPane: [PaneID: Int] = [:]
    @ObservationIgnored var paneIdByTabId: [TabID: Int] = [:]
    @ObservationIgnored var cwdByPaneId: [Int: String] = [:]
    @ObservationIgnored var isApplyingRemoteLayout = false
    @ObservationIgnored var isApplyingTmuxFocus = false
    @ObservationIgnored var lastClientSize: (cols: Int, rows: Int)?
    @ObservationIgnored var lastContentSizePoints: CGSize?
    @ObservationIgnored var lastDividerPositions: [UUID: CGFloat] = [:]
    @ObservationIgnored var splitTargets: [UUID: SplitResizeTarget] = [:]

    init(
        windowId: Int,
        panelId: UUID,
        connection: RemoteTmuxControlConnection,
        layout: RemoteTmuxLayoutNode,
        appearance: BonsplitConfiguration.Appearance,
        makePanel: @escaping (_ tmuxPaneId: Int) -> TerminalPanel?
    ) {
        self.windowId = windowId
        self.panelId = panelId
        self.connection = connection
        self.makePanel = makePanel
        self.layout = layout
        self.bonsplitController = Self.makeController(appearance: appearance)
        configureBonsplitController()
        reconcile(layout: layout)
    }

    var paneIDsInOrder: [Int] { layout.paneIDsInOrder }

    func panel(forPane tmuxPaneId: Int) -> TerminalPanel? { panelsByPaneId[tmuxPaneId] }

    func surface(forPane tmuxPaneId: Int) -> TerminalSurface? { panelsByPaneId[tmuxPaneId]?.surface }

    func tmuxPaneId(forTab tabId: TabID) -> Int? { paneIdByTabId[tabId] }

    func isFocused(tabId: TabID) -> Bool {
        tmuxPaneId(forTab: tabId).map { $0 == activePaneId } ?? false
    }

    func reconcile(layout newLayout: RemoteTmuxLayoutNode) {
        let previousLayout = layout
        let treeReady = bonsplitTreeMatches(layout: previousLayout)
        let livePaneIds = Set(newLayout.paneIDsInOrder)
        for paneId in newLayout.paneIDsInOrder where panelsByPaneId[paneId] == nil {
            guard let panel = makePanel(paneId) else { continue }
            panelsByPaneId[paneId] = panel
            connection?.seedPane(paneId: paneId)
        }
        layout = newLayout
        if newLayout == previousLayout, treeReady {
            refreshDividerPositions()
        } else if treeReady,
                  RemoteTmuxMirrorLayoutMath.sameShapeAndPaneIds(previousLayout, newLayout) {
            refreshDividerPositions()
        } else if treeReady,
                  applyTargetedStructureChange(from: previousLayout, to: newLayout) {
            refreshDividerPositions()
        } else {
            rebuildBonsplitTree()
        }
        for (paneId, panel) in panelsByPaneId where !livePaneIds.contains(paneId) {
            panel.close()
            connection?.unsubscribePanePath(paneId: paneId)
            connection?.unsubscribePaneReflow(paneId: paneId)
            panelsByPaneId[paneId] = nil
            cwdByPaneId[paneId] = nil
            if activePaneId == paneId { activePaneId = nil }
        }
        seedActivePaneIfNeeded()
        refreshPaneTitles()
        repushClientSizeForLastContentSize()
    }

    func routeOutput(paneId: Int, data: Data) {
        panelsByPaneId[paneId]?.surface.processRemoteOutput(data)
    }

    @discardableResult
    func updateClientSize(contentSizePoints: CGSize) -> Bool {
        lastContentSizePoints = contentSizePoints
        guard let cell = panelsByPaneId.values.lazy.compactMap({ $0.surface.cellSizePoints() }).first else {
            return false
        }
        let appearance = bonsplitController.configuration.appearance
        guard let grid = RemoteTmuxMirrorLayoutMath.clientGrid(
            layout: layout,
            contentSize: contentSizePoints,
            cellSize: cell,
            tabBarHeight: appearance.tabBarHeight,
            dividerThickness: appearance.dividerThickness
        ) else { return false }
        guard lastClientSize?.cols != grid.columns || lastClientSize?.rows != grid.rows else { return true }
        lastClientSize = (grid.columns, grid.rows)
        connection?.setClientSize(columns: grid.columns, rows: grid.rows)
        return true
    }

    func focus(pane tmuxPaneId: Int) {
        setActivePane(tmuxPaneId, fromTmux: false)
    }

    func setActivePane(_ paneId: Int, fromTmux: Bool) {
        guard layout.paneIDsInOrder.contains(paneId) else { return }
        if activePaneId != paneId { activePaneId = paneId }
        if let bonsplitPane = paneIdByPaneId[paneId] {
            isApplyingTmuxFocus = true
            bonsplitController.focusPane(bonsplitPane)
            isApplyingTmuxFocus = false
        }
        if !fromTmux {
            connection?.send("select-pane -t @\(windowId).%\(paneId)")
        }
    }

    @discardableResult
    func requestSplit(fromPane tmuxPaneId: Int, vertical: Bool) -> Bool {
        guard let connection, connection.connectionState == .connected else { return false }
        return connection.send("split-window \(vertical ? "-v" : "-h") -t @\(windowId).%\(tmuxPaneId)")
    }

    func requestKillPane(_ tmuxPaneId: Int) {
        connection?.send("kill-pane -t @\(windowId).%\(tmuxPaneId)")
    }

    func paneForegroundState(_ tmuxPaneId: Int) -> RemoteTmuxControlConnection.PaneForegroundState? {
        connection?.paneForegroundStates[tmuxPaneId]
    }

    func queryPaneActivity(
        _ tmuxPaneId: Int,
        completion: @escaping ([Int: RemoteTmuxControlConnection.PaneForegroundState]?) -> Void
    ) {
        guard let connection else { completion(nil); return }
        connection.queryPaneActivity(paneId: tmuxPaneId, completion: completion)
    }

    func updatePaneCwd(paneId: Int, path: String) {
        cwdByPaneId[paneId] = path
        updatePaneTitle(paneId)
    }

    func updatePaneTitle(_ paneId: Int) {
        guard let tabId = tabIdByPaneId[paneId] else { return }
        bonsplitController.updateTab(tabId, title: title(forPane: paneId))
    }

    func teardown() {
        for paneId in panelsByPaneId.keys {
            connection?.unsubscribePanePath(paneId: paneId)
            connection?.unsubscribePaneReflow(paneId: paneId)
        }
        for panel in panelsByPaneId.values { panel.close() }
        panelsByPaneId.removeAll()
        tabIdByPaneId.removeAll()
        paneIdByPaneId.removeAll()
        paneIdByBonsplitPane.removeAll()
        paneIdByTabId.removeAll()
        activePaneId = nil
    }
}

extension RemoteTmuxWindowMirror: BonsplitDelegate {
    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        guard !isApplyingRemoteLayout else { return true }
        if let tmuxPane = paneIdByTabId[tab.id] { onClosePaneRequest?(tmuxPane) }
        return false
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool {
        isApplyingRemoteLayout
    }

    func splitTabBar(_ controller: BonsplitController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool {
        guard !isApplyingRemoteLayout else { return true }
        if let tmuxPane = paneIdByBonsplitPane[pane] {
            _ = requestSplit(fromPane: tmuxPane, vertical: orientation == .vertical)
        }
        return false
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        guard !isApplyingRemoteLayout, !isApplyingTmuxFocus,
              let tmuxPane = paneIdByBonsplitPane[pane] else { return }
        guard activePaneId != tmuxPane else { return }
        focus(pane: tmuxPane)
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        guard !isApplyingRemoteLayout else { return }
        for (splitId, target) in splitTargets {
            guard let geometry = currentSplitGeometry(splitId: splitId),
                  abs(geometry.position - (lastDividerPositions[splitId] ?? geometry.position)) > 0.005 else {
                continue
            }
            lastDividerPositions[splitId] = geometry.position
            let cells = max(1, Int(round(CGFloat(target.totalCells) * geometry.position)))
            let flag = target.orientation == .horizontal ? "-x" : "-y"
            _ = connection?.send("resize-pane -t @\(windowId).%\(target.paneId) \(flag) \(cells)")
        }
    }
}
