import AppKit
import Bonsplit
import CmuxNestedTopology
import CmuxRemoteSession
import CmuxTerminal
import Foundation
import Observation

/// Owns per-pane ``TerminalPanel``s and Bonsplit layout for ONE mirrored Herdr tab.
///
/// Pane ids are Herdr strings (`w2:p34`). Layout comes from package
/// ``RemoteHerdrWindowMirror`` + ``RemoteHerdrHostApply`` verbs; Bonsplit is
/// imposed by ``RemoteHerdrWindowMirrorHost+Bonsplit``.
@MainActor
@Observable
final class RemoteHerdrWindowMirrorHost {
    let tabID: String
    let panelId: UUID

    var bonsplitController: BonsplitController

    @ObservationIgnored let makePanel: (_ paneID: String) -> TerminalPanel?
    @ObservationIgnored let paneIO: any RemoteHerdrPaneIO
    @ObservationIgnored weak var workspaceBonsplitController: BonsplitController?

    private(set) var layout: RemoteHerdrLayoutNode?
    private(set) var visibleLayout: RemoteHerdrLayoutNode?
    private(set) var zoomed = false
    private(set) var layoutStructureVersion = 0
    private(set) var activePaneID: String?
    private(set) var windowTitle = "herdr"
    private(set) var mirrorState: RemoteHerdrWindowMirrorState?

    @ObservationIgnored var isVisibleForSizing = false
    @ObservationIgnored var isTornDown = false
    @ObservationIgnored var isApplyingRemoteLayout = false
    @ObservationIgnored private var applyingRemoteLayoutDepth = 0
    @ObservationIgnored var isApplyingFocus = false

    @ObservationIgnored var panelsByPaneId: [String: TerminalPanel] = [:]
    @ObservationIgnored var tabIdByPaneId: [String: TabID] = [:]
    @ObservationIgnored var paneIdByPaneId: [String: PaneID] = [:]
    @ObservationIgnored var paneIdByBonsplitPane: [PaneID: String] = [:]
    @ObservationIgnored var paneIdByTabId: [TabID: String] = [:]
    @ObservationIgnored var lastDividerPositions: [UUID: CGFloat] = [:]

    @ObservationIgnored var onTerminalPanelAdded: ((TerminalPanel) -> Void)?
    @ObservationIgnored var onTerminalPanelRemoved: ((TerminalPanel) -> Void)?
    /// User chrome close → ``pane.close`` (session host owns the RPC).
    @ObservationIgnored var onClosePaneRequest: ((String) -> Void)?
    /// User focus → ``pane.focus`` (session host owns the RPC).
    @ObservationIgnored var onFocusPaneRequest: ((String) -> Void)?
    /// User split → ``pane.split`` (session host owns the RPC).
    @ObservationIgnored var onSplitPaneRequest: ((_ paneID: String, _ vertical: Bool) -> Void)?
    /// Divider / client size claim → ``pane.resize`` (session host owns the RPC).
    @ObservationIgnored var onResizePaneRequest: ((_ paneID: String, _ cols: Int, _ rows: Int) -> Void)?
    /// Serialized pane input — owned by ``RemoteHerdrSessionHost`` (no fire-and-forget `pane.send`).
    @ObservationIgnored var onSendInputRequest: ((_ paneID: String, _ text: String) -> Void)?

    /// Container size for feed-forward client claims (points).
    @ObservationIgnored var containerSizePt: CGSize?
    @ObservationIgnored var containerScale: CGFloat = 2
    @ObservationIgnored var renderFrameSize: CGSize?
    @ObservationIgnored var hostProbeView: NSView?
    @ObservationIgnored var sizingPassScheduled = false
    @ObservationIgnored var lastClaimedClientGrid: (cols: Int, rows: Int)?
    @ObservationIgnored var dividerResizeSentSinceDragBegan = false
    @ObservationIgnored var pendingDividerDragEnd = false
    @ObservationIgnored private let sizing = RemoteHerdrSizing()

    var surfaceIDsInLayoutOrder: [UUID] {
        let order = (visibleLayout ?? layout)?.paneIDsInOrder ?? Array(panelsByPaneId.keys)
        return order.compactMap { panelsByPaneId[$0]?.id }
    }

    var renderedLayout: RemoteHerdrLayoutNode? { visibleLayout ?? layout }

    init(
        tabID: String,
        panelId: UUID,
        appearance: BonsplitConfiguration.Appearance = .init(),
        workspaceBonsplitController: BonsplitController? = nil,
        paneIO: any RemoteHerdrPaneIO,
        makePanel: @escaping (_ paneID: String) -> TerminalPanel?
    ) {
        self.tabID = tabID
        self.panelId = panelId
        self.paneIO = paneIO
        self.makePanel = makePanel
        self.workspaceBonsplitController = workspaceBonsplitController
        let initialConfiguration = workspaceBonsplitController?.configuration
            ?? BonsplitConfiguration(appearance: appearance)
        self.bonsplitController = Self.makeController(configuration: initialConfiguration)
        configureBonsplitController()
    }

    func panel(forPane paneID: String) -> TerminalPanel? { panelsByPaneId[paneID] }

    func isFocused(tabId: TabID) -> Bool {
        guard let paneID = paneIdByTabId[tabId] else { return false }
        return paneID == activePaneID
    }

    func herdrPaneId(forTab tabId: TabID) -> String? {
        paneIdByTabId[tabId]
    }

    /// Reconcile + HostApply against a Herdr window update.
    func apply(window: RemoteHerdrWindow) {
        guard !isTornDown else { return }
        let previous = mirrorState
        let previousRendered = previous.map { $0.visibleLayout ?? $0.layout }
        let (next, result) = RemoteHerdrWindowMirror.apply(window: window, previous: previous)
        mirrorState = next
        windowTitle = RemoteHerdrControl.applySessionTitle(window.title, current: windowTitle) ?? window.title
        if layoutStructureVersion != next.layoutStructureVersion {
            layoutStructureVersion = next.layoutStructureVersion
        }
        layout = next.layout
        visibleLayout = next.visibleLayout
        zoomed = next.zoomed

        guard let plan = RemoteHerdrImpose.plan(
            from: result,
            previousRendered: previousRendered,
            title: window.title
        ) else {
            // Still create panels when the layout cannot produce a divider tree.
            for paneID in result.createdPaneIDs where panelsByPaneId[paneID] == nil {
                createPanelIfNeeded(paneID: paneID)
            }
            if let focus = result.focusPaneID {
                noteRemoteActivePane(focus)
            }
            return
        }
        let actions = RemoteHerdrHostApply.actions(result: result, plan: plan)
        beginApplyingRemoteLayout()
        defer { endApplyingRemoteLayout() }
        for action in actions {
            applyHostAction(action, plan: plan)
        }
        if let focus = result.focusPaneID {
            noteRemoteActivePane(focus)
        }
    }

    private func applyHostAction(
        _ action: RemoteHerdrHostAction,
        plan: RemoteHerdrImposePlan
    ) {
        switch action.op {
        case "create_panel":
            if let paneID = action.paneID {
                createPanelIfNeeded(paneID: paneID)
            }
        case "close_panel":
            if let paneID = action.paneID, let panel = panelsByPaneId.removeValue(forKey: paneID) {
                onTerminalPanelRemoved?(panel)
                GhosttyApp.terminalSurfaceRegistry.unregister(panel.surface)
                panel.close()
            }
        case "rebuild_tree":
            rebuildBonsplitTree()
        case "keep_tree":
            // Divider impose runs once below for keep_tree / rebuild / expand / remove.
            break
        case "expand_leaf":
            if let paneID = action.paneID,
               let from = action.splitFromPaneID,
               let orientation = action.orientation {
                expandLeaf(
                    existingPaneID: from,
                    newPaneID: paneID,
                    orientation: orientation,
                    insertFirst: action.insertFirst,
                    fraction: action.fraction ?? 0.5
                )
            } else {
                rebuildBonsplitTree()
            }
        case "remove_leaf":
            if let paneID = action.paneID {
                removeLeaf(paneID: paneID)
            } else {
                rebuildBonsplitTree()
            }
        case "impose_divider":
            // Applied as a full tree walk after structural verbs.
            break
        case "focus":
            if let paneID = action.paneID {
                noteRemoteActivePane(paneID)
            }
        default:
            break
        }
        // After structural mutations, impose divider fractions once.
        if ["rebuild_tree", "expand_leaf", "remove_leaf", "keep_tree"].contains(action.op) {
            imposeDividerTree(plan.dividerTree)
        }
    }

    func deliverOutput(paneID: String, data: Data, fullRedraw: Bool) {
        guard let panel = panelsByPaneId[paneID], !isTornDown else { return }
        if fullRedraw {
            _ = panel.surface.clearScreenKeepingScrollback()
        }
        panel.surface.processRemoteOutput(data)
    }

    func noteRemoteActivePane(_ paneID: String) {
        guard panelsByPaneId[paneID] != nil else { return }
        projectActivePane(paneID)
    }

    func projectActivePane(_ paneID: String) {
        guard panelsByPaneId[paneID] != nil else { return }
        isApplyingFocus = true
        defer { isApplyingFocus = false }
        if activePaneID != paneID { activePaneID = paneID }
        focusBonsplitPane(forHerdrPane: paneID)
    }

    /// Records the user-focused pane and asks Herdr to make it active.
    func setActivePane(_ paneID: String, fromProvider: Bool) {
        guard panelsByPaneId[paneID] != nil, !isApplyingFocus else { return }
        projectActivePane(paneID)
        if !fromProvider {
            onFocusPaneRequest?(paneID)
        }
    }

    /// Records the user-focused pane and asks Herdr to make it active.
    func focus(pane paneID: String) {
        setActivePane(paneID, fromProvider: false)
    }

    @discardableResult
    func createPanelIfNeeded(paneID: String) -> TerminalPanel? {
        guard panelsByPaneId[paneID] == nil else { return panelsByPaneId[paneID] }
        guard let panel = makePanel(paneID) else { return nil }
        panelsByPaneId[paneID] = panel
        onTerminalPanelAdded?(panel)
        if var state = mirrorState {
            RemoteHerdrWindowMirror.bindSurface(
                paneID: paneID,
                surfaceID: panel.id,
                state: &state
            )
            mirrorState = state
        }
        return panel
    }

    func teardown() {
        isTornDown = true
        isVisibleForSizing = false
        sizingPassScheduled = false
        containerSizePt = nil
        renderFrameSize = nil
        lastClaimedClientGrid = nil
        hostProbeView = nil
        for panel in panelsByPaneId.values {
            onTerminalPanelRemoved?(panel)
            GhosttyApp.terminalSurfaceRegistry.unregister(panel.surface)
            panel.close()
        }
        panelsByPaneId.removeAll()
        tabIdByPaneId.removeAll()
        paneIdByPaneId.removeAll()
        paneIdByBonsplitPane.removeAll()
        paneIdByTabId.removeAll()
    }

    func paneGridsPayload() -> [String: Any] {
        let layout = renderedLayout
        var panes: [[String: Any]] = []
        for paneID in panelsByPaneId.keys.sorted() {
            guard let panel = panelsByPaneId[paneID] else { continue }
            let leaf = layout?.firstLeaf(withPaneID: paneID)
            let assignedCols = leaf.map { max(1, $0.width) } ?? 80
            let assignedRows = leaf.map { max(1, $0.height) } ?? 24
            let axis = layout?.exactAxisFlags(forPaneID: paneID) ?? (false, false)
            panes.append([
                "pane_id": paneID,
                "assigned_cols": assignedCols,
                "assigned_rows": assignedRows,
                "rendered_cols": assignedCols,
                "rendered_rows": assignedRows,
                "exact_cols": axis.exactCols,
                "exact_rows": axis.exactRows,
                "has_panel": true,
            ])
        }
        return [
            "tab_id": tabID,
            "panes": panes,
            "structure_version": layoutStructureVersion,
            "zoomed": zoomed,
            "visible_for_sizing": isVisibleForSizing,
        ]
    }
}
