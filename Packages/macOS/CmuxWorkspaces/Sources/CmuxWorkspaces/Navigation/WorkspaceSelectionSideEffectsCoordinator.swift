public import Foundation

/// Sequences the per-window selection side-effect chain the legacy `TabManager`
/// god object ran inline in `selectedTabId`'s `didSet`: the group auto-expand,
/// the previous/next focus-history recording, and the deferred AppKit hop that
/// focuses the selected workspace's panel, updates the window title, and
/// dismisses the focused panel's notification.
///
/// The coordinator owns the *ordering* over the CmuxWorkspaces models — the
/// ``FocusedSurfaceModel`` remembered-focus bookkeeping and the
/// ``FocusHistoryNavigating`` record/suppress machinery — and the
/// `selectionSideEffectsGeneration` guard that lets a later selection cancel an
/// earlier selection's still-pending deferred turn. Every app-coupled effect
/// (Sentry breadcrumb, the `Workspace`-god focused-panel read, the
/// `CmuxWorkspaceSelected` publish, the cross-package notification-dismissal
/// context, the DEBUG switch tracing, the `DispatchQueue.main.async` hop, and
/// the deferred window-title / notification-dismissal effects) inverts through
/// ``WorkspaceSelectionSideEffectsHosting``.
///
/// `@MainActor` because the chain runs in one main-actor turn driven by a
/// `selectedTabId` assignment, and the model, the focus models, and the host all
/// live there; co-locating removes any bridging (mirrors the sibling workspace
/// coordinators' isolation ruling). This is a byte-identical lift of the legacy
/// `didSet` body, so the generation guard, the synchronous record ordering, and
/// the deferred-hop structure are preserved verbatim.
@MainActor
public final class WorkspaceSelectionSideEffectsCoordinator<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>
    private let focusedSurface: FocusedSurfaceModel
    private let focusHistory: any FocusHistoryNavigating
    private weak var host: (any WorkspaceSelectionSideEffectsHosting)?

    /// Monotonic token identifying the latest selection change. The deferred
    /// turn captures the token at schedule time and only applies its effects
    /// when the token is still current, so a rapid re-selection cancels the
    /// earlier selection's pending effects (legacy
    /// `selectionSideEffectsGeneration`).
    private var selectionSideEffectsGeneration: UInt64 = 0

    /// Whether focus changes are currently recorded (legacy
    /// `TabManager.shouldRecordFocusHistory` gate, forwarded to the model).
    private var shouldRecordFocusHistory: Bool {
        focusHistory.shouldRecordFocusHistory
    }

    /// Creates the coordinator over the window's workspace-list model and the
    /// focused-surface / focus-history models it sequences.
    public init(
        model: WorkspacesModel<Tab>,
        focusedSurface: FocusedSurfaceModel,
        focusHistory: any FocusHistoryNavigating
    ) {
        self.model = model
        self.focusedSurface = focusedSurface
        self.focusHistory = focusHistory
    }

    /// Attaches the window-side host that performs the app-coupled selection
    /// effects. Must be called before the first selection change.
    public func attach(host: any WorkspaceSelectionSideEffectsHosting) {
        self.host = host
    }

    /// Runs the selection side-effect chain after `selectedTabId` changed from
    /// `oldValue` (legacy `selectedTabId` `didSet`). No-op when the selection did
    /// not actually change.
    public func selectedWorkspaceIdDidChange(from oldValue: UUID?) {
        guard model.selectedTabId != oldValue else { return }
        if let host, !host.isSelectionSideEffectsRestoring {
            model.expandWorkspaceGroupForSelectionIfNeeded()
        }
        host?.recordWorkspaceSwitchBreadcrumb(tabCount: model.tabs.count)
        let previousTabId = oldValue
        if let previousTabId {
            focusedSurface.recordRememberedFocusForPreviousSelection(previousTabId)
        }
        if shouldRecordFocusHistory {
            if let previousTabId {
                focusHistory.recordFocusInHistory(
                    workspaceId: previousTabId,
                    panelId: host?.focusedPanelId(forWorkspaceId: previousTabId),
                    preservingForwardBranch: false
                )
            }
            if let selectedTabId = model.selectedTabId,
               model.tabs.contains(where: { $0.id == selectedTabId }) {
                let selectedEntry = FocusHistoryEntry(
                    workspaceId: selectedTabId,
                    panelId: focusedSurface.rememberedFocusedPanelId(selectedTabId)
                )
                focusHistory.recordFocusInHistory(
                    workspaceId: selectedTabId,
                    panelId: focusHistory.resolvedFocusHistoryPanelId(for: selectedEntry),
                    preservingForwardBranch: false
                )
            }
        }
        host?.publishWorkspaceSelectedChange(fromPreviousWorkspaceId: previousTabId)
        host?.takePendingNotificationDismissalContextForDeferredSideEffects()
        host?.debugLogSelectionDidChange(
            fromPreviousWorkspaceId: previousTabId,
            toSelectedWorkspaceId: model.selectedTabId
        )
        selectionSideEffectsGeneration &+= 1
        let generation = selectionSideEffectsGeneration
        if !shouldRecordFocusHistory {
            focusHistory.markSuppressedSelectionSideEffectGeneration(generation)
        }
        host?.scheduleDeferredSelectionSideEffects(
            generation: generation,
            previousWorkspaceId: previousTabId
        )
    }

    /// Applies the deferred selection side effects for `generation`, run by the
    /// host inside its `DispatchQueue.main.async` hop (legacy deferred closure).
    /// Bails when a later selection has superseded `generation`.
    public func runDeferredSelectionSideEffects(generation: UInt64, previousWorkspaceId: UUID?) {
        let suppressFocusHistory = focusHistory.consumeSuppressedSelectionSideEffectGeneration(generation)
        guard selectionSideEffectsGeneration == generation else { return }
        let applySelectionSideEffects = {
            self.focusedSurface.focusSelectedWorkspacePanel(previousWorkspaceId: previousWorkspaceId)
            self.host?.applyDeferredSelectionAppEffects()
        }
        if suppressFocusHistory {
            focusHistory.withFocusHistoryRecordingSuppressed(applySelectionSideEffects)
        } else {
            applySelectionSideEffects()
        }
        host?.debugLogSelectionSideEffectsDone()
    }

    /// Bumps the generation so any in-flight deferred turn is cancelled (legacy
    /// `selectionSideEffectsGeneration &+= 1` in the window-reset path).
    public func invalidateDeferredSelectionSideEffects() {
        selectionSideEffectsGeneration &+= 1
    }
}
