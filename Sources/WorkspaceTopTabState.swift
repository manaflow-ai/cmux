import Foundation
import Bonsplit

struct WorkspaceTopTabPendingTabSelectionRequest {
    let tabId: TabID
    let pane: PaneID
    let reassertAppKitFocus: Bool
    let focusIntent: PanelFocusIntent?
    let previousTerminalHostedView: GhosttySurfaceScrollView?
}

struct WorkspaceTopTabPendingNonFocusSplitFocusReassert {
    let generation: UInt64
    let preferredPanelId: UUID
    let splitPanelId: UUID
}

@MainActor
final class WorkspaceTopTabState: Identifiable {
    let id: UUID
    let bonsplitController: BonsplitController

    var surfaceIdToPanelId: [TabID: UUID] = [:]
    var forceCloseTabIds: Set<TabID> = []
    var pendingCloseConfirmTabIds: Set<TabID> = []
    var postCloseSelectTabId: [TabID: TabID] = [:]
    var pendingPaneClosePanelIds: [UUID: [UUID]] = [:]
    var pendingClosedBrowserRestoreSnapshots: [TabID: ClosedBrowserPanelRestoreSnapshot] = [:]
    var isApplyingTabSelection = false
    var pendingTabSelection: WorkspaceTopTabPendingTabSelectionRequest?
    var isReconcilingFocusState = false
    var focusReconcileScheduled = false
#if DEBUG
    var debugFocusReconcileScheduledDuringDetachCount: Int = 0
    var debugLastDidMoveTabTimestamp: TimeInterval = 0
    var debugDidMoveTabEventCount: UInt64 = 0
#endif
    var geometryReconcileScheduled = false
    var geometryReconcileNeedsRerun = false
    var isNormalizingPinnedTabOrder = false
    var pendingNonFocusSplitFocusReassert: WorkspaceTopTabPendingNonFocusSplitFocusReassert?
    var nonFocusSplitFocusReassertGeneration: UInt64 = 0
    var detachingTabIds: Set<TabID> = []
    var pendingDetachedSurfaces: [TabID: Workspace.DetachedSurfaceTransfer] = [:]
    var activeDetachCloseTransactions: Int = 0
    var isProgrammaticSplit = false
    var lastTerminalConfigInheritancePanelId: UUID?
    var lastTerminalConfigInheritanceFontPoints: Float?
    var terminalInheritanceFontPointsByPanelId: [UUID: Float] = [:]
    var processTitle: String
    var customTitle: String?

    init(
        id: UUID = UUID(),
        bonsplitController: BonsplitController,
        processTitle: String,
        customTitle: String? = nil
    ) {
        self.id = id
        self.bonsplitController = bonsplitController
        self.processTitle = processTitle
        self.customTitle = customTitle
    }

    var isDetachingCloseTransaction: Bool {
        activeDetachCloseTransactions > 0
    }
}
