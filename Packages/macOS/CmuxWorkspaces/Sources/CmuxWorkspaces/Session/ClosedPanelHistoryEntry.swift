public import Foundation

/// A persisted recently-closed panel, the value the
/// ``ClosedPanelHistoryCoordinator`` pushes onto the closed-item history stack
/// when an eligible panel closes and consumes when the user reopens it.
///
/// This is the single owner of the closed-panel value type; the app target reuses
/// it as `typealias ClosedPanelHistoryEntry = CmuxWorkspaces.ClosedPanelHistoryEntry<SessionPanelSnapshot>`.
/// It is a pure `Codable`, `Sendable` value: the workspace and pane ids it closed
/// in, the sibling-tab anchor a same-pane restore prefers, whether the original
/// pane should be tried first, the tab index it occupied, the captured panel
/// `Snapshot`, and the fallback split placement used when the original pane no
/// longer exists.
///
/// `Snapshot` is generic because the captured panel snapshot (`SessionPanelSnapshot`)
/// is owned by the executable target, the same reason ``SessionSnapshotWindowInput``
/// stays generic over its `Window`. The coordinator decides where to restore from
/// these fields; the live panel/pane recreation runs app-side behind
/// ``WorkspaceClosedPanelHistoryHosting``.
public struct ClosedPanelHistoryEntry<Snapshot>: Codable, Sendable where Snapshot: Codable & Sendable {
    /// The id of the workspace the panel was closed in.
    public let workspaceId: UUID
    /// The id of the pane the panel was closed in.
    public let paneId: UUID
    /// The panel id of the sibling tab a same-pane restore anchors next to (the
    /// pane's chosen neighbor of the closing tab), or `nil` when the closing tab
    /// was the pane's only tab.
    public let paneAnchorPanelId: UUID?
    /// Whether a restore should first try recreating the panel in its original
    /// pane (`true`) or skip straight to the anchor/fallback routing (`false`,
    /// set when the entry is remapped to a different workspace).
    public let restoreInOriginalPane: Bool
    /// The tab index the panel occupied within its pane, used to re-insert it at
    /// the same position on restore.
    public let tabIndex: Int
    /// The captured panel snapshot a restore rebuilds the live panel from.
    public let snapshot: Snapshot
    /// The split placement used when neither the original pane nor the anchor pane
    /// exists, recreating the pane the panel lived in beside a surviving anchor.
    public let fallbackSplitPlacement: ClosedPanelSplitPlacement?

    /// Creates a closed-panel history entry.
    public init(
        workspaceId: UUID,
        paneId: UUID,
        paneAnchorPanelId: UUID? = nil,
        restoreInOriginalPane: Bool = true,
        tabIndex: Int,
        snapshot: Snapshot,
        fallbackSplitPlacement: ClosedPanelSplitPlacement? = nil
    ) {
        self.workspaceId = workspaceId
        self.paneId = paneId
        self.paneAnchorPanelId = paneAnchorPanelId
        self.restoreInOriginalPane = restoreInOriginalPane
        self.tabIndex = tabIndex
        self.snapshot = snapshot
        self.fallbackSplitPlacement = fallbackSplitPlacement
    }
}
