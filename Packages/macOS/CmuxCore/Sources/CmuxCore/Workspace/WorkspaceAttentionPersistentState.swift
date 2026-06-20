public import Foundation

/// The persisted unread/attention facts a flash decision is evaluated against.
///
/// Snapshots the per-workspace indicator state at flash time: which panels are
/// unread (notification-derived or restored), which panel currently shows the
/// focused-read indicator, and which panels the user manually marked unread.
/// ``WorkspaceAttentionFlashDecision/decide(targetPanelID:reason:persistentState:)``
/// reads it to suppress a navigation flash when a *different* panel already
/// competes for attention.
///
/// Pure value lifted out of the legacy `Workspace` god object so the flash
/// decision is testable without a live workspace; the live reads that build it
/// (`panels.keys`, the notification store, `manualUnreadPanelIds`) stay
/// app-coupled and feed this struct through the unread sub-model's seam.
public struct WorkspaceAttentionPersistentState: Equatable, Sendable {
    /// Panels currently unread (restored indicator or live notification).
    public var unreadPanelIDs: Set<UUID>
    /// The panel showing the focused-read indicator, if any.
    public var focusedReadPanelID: UUID?
    /// Panels the user manually marked unread.
    public var manualUnreadPanelIDs: Set<UUID>

    /// Creates a persistent-state snapshot. All fields default to empty/nil so
    /// callers can build it incrementally, matching the legacy struct.
    public init(
        unreadPanelIDs: Set<UUID> = [],
        focusedReadPanelID: UUID? = nil,
        manualUnreadPanelIDs: Set<UUID> = []
    ) {
        self.unreadPanelIDs = unreadPanelIDs
        self.focusedReadPanelID = focusedReadPanelID
        self.manualUnreadPanelIDs = manualUnreadPanelIDs
    }

    /// Every panel that currently carries any attention indicator (unread,
    /// manual unread, or focused-read).
    public var indicatorPanelIDs: Set<UUID> {
        var ids = unreadPanelIDs.union(manualUnreadPanelIDs)
        if let focusedReadPanelID {
            ids.insert(focusedReadPanelID)
        }
        return ids
    }

    /// Whether a panel *other than* `panelID` already carries an indicator,
    /// i.e. would compete with a flash on `panelID`.
    public func hasCompetingIndicator(for panelID: UUID) -> Bool {
        indicatorPanelIDs.contains(where: { $0 != panelID })
    }
}
