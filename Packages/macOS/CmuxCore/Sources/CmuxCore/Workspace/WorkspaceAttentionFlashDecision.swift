public import Foundation

/// The resolved verdict for one attention-flash request.
///
/// Carries the target panel, the reason, and whether the flash is allowed to
/// play. A navigation flash is suppressed when another panel already competes
/// for attention; every other reason always plays. The decision is pure, so
/// the unread sub-model can compute it without touching live workspace state.
///
/// Lifted with ``decide(targetPanelID:reason:persistentState:)`` out of the
/// legacy `Workspace.WorkspaceAttentionCoordinator` namespace; the UI
/// presentation half of that namespace (ring colors / styles) stays in the app
/// target because it depends on AppKit.
public struct WorkspaceAttentionFlashDecision: Equatable, Sendable {
    /// The panel the flash targets.
    public let panelID: UUID
    /// Why the flash was requested.
    public let reason: WorkspaceAttentionFlashReason
    /// Whether the flash is allowed to play.
    public let isAllowed: Bool

    /// Creates a flash decision.
    public init(panelID: UUID, reason: WorkspaceAttentionFlashReason, isAllowed: Bool) {
        self.panelID = panelID
        self.reason = reason
        self.isAllowed = isAllowed
    }

    /// Resolves whether a flash on `targetPanelID` for `reason` may play given
    /// `persistentState`. A `.navigation` flash is suppressed when another panel
    /// already competes for attention; all other reasons always play. Faithful
    /// lift of the legacy `WorkspaceAttentionCoordinator.decideFlash(...)`.
    public static func decide(
        targetPanelID: UUID,
        reason: WorkspaceAttentionFlashReason,
        persistentState: WorkspaceAttentionPersistentState
    ) -> WorkspaceAttentionFlashDecision {
        let isAllowed: Bool
        switch reason {
        case .navigation:
            isAllowed = !persistentState.hasCompetingIndicator(for: targetPanelID)
        case .notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug:
            isAllowed = true
        }

        return WorkspaceAttentionFlashDecision(
            panelID: targetPanelID,
            reason: reason,
            isAllowed: isAllowed
        )
    }
}
