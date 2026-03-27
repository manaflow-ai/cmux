import AppKit
import Foundation
import Combine
import Bonsplit

// MARK: - WorkspaceTab

/// A single tab within a workspace, holding a BonsplitController and all
/// panel-related state. Each workspace contains one or more WorkspaceTabs.
///
/// Phase 1: every Workspace starts with exactly one WorkspaceTab. Workspace
/// provides computed pass-through properties so that all existing callers
/// continue to compile and behave identically.
@MainActor
final class WorkspaceTab: Identifiable, ObservableObject {
    let id: UUID

    /// The bonsplit controller managing split panes for this tab.
    let bonsplitController: BonsplitController

    /// Back-reference to the owning workspace. Needed for operations that touch
    /// workspace-level state (e.g. BonsplitDelegate callbacks, remote sessions).
    weak var workspace: Workspace?

    /// User-set custom title for this tab. When nil, the tab bar derives a title from panel state.
    @Published var customTitle: String?

    // MARK: - Panel State

    /// All panels in this tab, keyed by panel UUID.
    @Published var panels: [UUID: any Panel] = [:]

    /// Mapping from bonsplit TabID (surface ID) to panel UUID.
    var surfaceIdToPanelId: [TabID: UUID] = [:]

    /// Combine subscriptions for panel updates (e.g. browser title changes).
    var panelSubscriptions: [UUID: AnyCancellable] = [:]

    // MARK: - Panel Metadata

    /// Published display title for each panel.
    @Published var panelTitles: [UUID: String] = [:]

    /// User-assigned custom titles for panels.
    @Published var panelCustomTitles: [UUID: String] = [:]

    /// Reported working directory for each panel.
    @Published var panelDirectories: [UUID: String] = [:]

    /// Git branch state per panel.
    @Published var panelGitBranches: [UUID: SidebarGitBranchState] = [:]

    /// Pull request state per panel.
    @Published var panelPullRequests: [UUID: SidebarPullRequestState] = [:]

    /// Pinned panel IDs.
    @Published var pinnedPanelIds: Set<UUID> = []

    /// Manually-marked-unread panel IDs.
    @Published var manualUnreadPanelIds: Set<UUID> = []

    /// Timestamps for when panels were manually marked unread.
    var manualUnreadMarkedAt: [UUID: Date] = [:]

    /// Listening ports per panel.
    @Published var surfaceListeningPorts: [UUID: [Int]] = [:]

    /// TTY names per panel.
    var surfaceTTYNames: [UUID: String] = [:]

    // MARK: - Terminal Config Inheritance

    /// Last terminal panel used as an inheritance source (typically last focused terminal).
    var lastTerminalConfigInheritancePanelId: UUID?

    /// Last known terminal font points from inheritance sources.
    var lastTerminalConfigInheritanceFontPoints: Float?

    /// Per-panel inherited zoom lineage.
    var terminalInheritanceFontPointsByPanelId: [UUID: Float] = [:]

    // MARK: - Internal Panel State

    /// When true, suppresses auto-creation in didSplitPane (programmatic splits handle their own panels).
    var isProgrammaticSplit = false

    var debugStressPreloadSelectionDepth = 0

    /// Shell activity state per panel.
    var panelShellActivityStates: [UUID: Workspace.PanelShellActivityState] = [:]

    /// Scrollback text preserved across session restore cycles.
    var restoredTerminalScrollbackByPanelId: [UUID: String] = [:]

    // MARK: - Tab Close / Focus Tracking

    /// Tab IDs that are allowed to close even if they would normally require confirmation.
    var forceCloseTabIds: Set<TabID> = []

    /// Tab IDs currently showing a close confirmation prompt.
    var pendingCloseConfirmTabIds: Set<TabID> = []

    /// Tab IDs whose next close should be treated as an explicit workspace-close gesture.
    var explicitUserCloseTabIds: Set<TabID> = []

    /// Deterministic tab selection to apply after a tab closes.
    var postCloseSelectTabId: [TabID: TabID] = [:]

    /// Panel IDs pending pane-close operations.
    var pendingPaneClosePanelIds: [UUID: [UUID]] = [:]

    /// Closed browser panel snapshots for restore.
    var pendingClosedBrowserRestoreSnapshots: [TabID: ClosedBrowserPanelRestoreSnapshot] = [:]

    var isApplyingTabSelection = false
    var pendingTabSelection: PendingTabSelectionRequest?
    var isReconcilingFocusState = false
    var focusReconcileScheduled = false

    #if DEBUG
    var debugFocusReconcileScheduledDuringDetachCount: Int = 0
    var debugLastDidMoveTabTimestamp: TimeInterval = 0
    var debugDidMoveTabEventCount: UInt64 = 0
    #endif

    var layoutFollowUpObservers: [NSObjectProtocol] = []
    var layoutFollowUpPanelsCancellable: AnyCancellable?
    var layoutFollowUpTimeoutWorkItem: DispatchWorkItem?
    var layoutFollowUpReason: String?
    var layoutFollowUpTerminalFocusPanelId: UUID?
    var layoutFollowUpBrowserPanelId: UUID?
    var layoutFollowUpBrowserExitFocusPanelId: UUID?
    var layoutFollowUpNeedsGeometryPass = false
    var layoutFollowUpAttemptScheduled = false
    var layoutFollowUpStalledAttemptCount = 0
    var isAttemptingLayoutFollowUp = false
    var isNormalizingPinnedTabOrder = false
    var pendingNonFocusSplitFocusReassert: PendingNonFocusSplitFocusReassert?
    var nonFocusSplitFocusReassertGeneration: UInt64 = 0

    // MARK: - Tab Detach / Attach

    var detachingTabIds: Set<TabID> = []
    var pendingDetachedSurfaces: [TabID: Workspace.DetachedSurfaceTransfer] = [:]
    var activeDetachCloseTransactions: Int = 0
    var isDetachingCloseTransaction: Bool { activeDetachCloseTransactions > 0 }

    // MARK: - Layout Snapshot

    @Published var tmuxLayoutSnapshot: LayoutSnapshot?
    @Published var tmuxWorkspaceFlashPanelId: UUID?
    @Published var tmuxWorkspaceFlashReason: WorkspaceAttentionFlashReason?
    @Published var tmuxWorkspaceFlashToken: UInt64 = 0

    // MARK: - Nested Types

    struct PendingTabSelectionRequest {
        let tabId: TabID
        let pane: PaneID
        let reassertAppKitFocus: Bool
        let focusIntent: PanelFocusIntent?
        let previousTerminalHostedView: GhosttySurfaceScrollView?
    }

    struct PendingNonFocusSplitFocusReassert {
        let generation: UInt64
        let preferredPanelId: UUID
        let splitPanelId: UUID
    }

    // MARK: - Computed

    /// The currently focused pane's panel ID.
    var focusedPanelId: UUID? {
        guard let paneId = bonsplitController.focusedPaneId,
              let tab = bonsplitController.selectedTab(inPane: paneId) else {
            return nil
        }
        return surfaceIdToPanelId[tab.id]
    }

    /// The currently focused terminal panel (if any).
    var focusedTerminalPanel: TerminalPanel? {
        guard let panelId = focusedPanelId,
              let panel = panels[panelId] as? TerminalPanel else {
            return nil
        }
        return panel
    }

    /// The derived display title for this tab, preferring the focused panel's directory.
    var derivedTitle: String {
        // Prefer focused panel
        if let focusedId = focusedPanelId {
            if let dir = panelDirectories[focusedId], !dir.isEmpty {
                let base = (dir as NSString).lastPathComponent
                if !base.isEmpty { return base }
            }
            if let title = panelTitles[focusedId]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty { return title }
        }
        // Fall back to any panel
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let dir = panelDirectories[panelId], !dir.isEmpty {
                let base = (dir as NSString).lastPathComponent
                if !base.isEmpty { return base }
            }
        }
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let title = panelTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty { return title }
        }
        return ""
    }

    // MARK: - Init

    init(bonsplitController: BonsplitController) {
        self.id = UUID()
        self.bonsplitController = bonsplitController
    }
}
