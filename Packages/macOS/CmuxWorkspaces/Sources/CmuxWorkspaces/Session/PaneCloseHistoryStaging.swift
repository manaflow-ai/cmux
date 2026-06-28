public import Foundation
public import Observation

/// The per-workspace pane-close history-entry staging sub-model: owns the
/// recently-closed-panel history entries the legacy `Workspace` god object
/// staged between a pane-close approval and the close landing.
///
/// Bonsplit's pane-close does not emit a per-tab `didCloseTab` callback, so the
/// `Workspace` `BonsplitDelegate` builds each doomed tab's recently-closed
/// history entry against the *pre-close* tree in
/// `splitTabBar(_:shouldClosePane:)` and stages it here keyed by the closing
/// pane's id, then consumes the staged entries in
/// `splitTabBar(_:didClosePane:)` to push them onto the closed-item history.
///
/// This is the history-entry sibling of ``SplitLifecycleCoordinator``'s pure
/// `UUID`-keyed `pendingPaneClosePanelIds`. That panel-id map moved into the
/// lower `CmuxPanes` package, but the entry *values* are the app-target
/// `ClosedPanelHistoryEntry` (it stores a `SessionPanelSnapshot`, which lives in
/// the app target), a type neither `CmuxPanes` nor `CmuxWorkspaces` can name. So
/// this staging is generic over the entry value: the workspace instantiates it
/// as `PaneCloseHistoryStaging<ClosedPanelHistoryEntry>`, builds the concrete
/// entries app-side via `closedPanelHistoryEntry(...)`, and threads them through
/// as the opaque ``Entry``.
///
/// None of the staged state was `@Published` on the legacy god object, so this
/// storage move carries no observer-parity hooks (matching
/// ``SplitLifecycleCoordinator``).
@MainActor
@Observable
public final class PaneCloseHistoryStaging<Entry> {
    /// The recently-closed-panel history entries staged for an approved pane
    /// close, keyed by the closing pane's id (legacy
    /// `Workspace.pendingPaneCloseHistoryEntries`). Recorded against the
    /// pre-close tree in `splitTabBar(_:shouldClosePane:)` and consumed in
    /// `splitTabBar(_:didClosePane:)`.
    public var pendingEntries: [UUID: [Entry]] = [:]

    /// Creates an idle staging; the owning workspace drives it from its
    /// `BonsplitDelegate` close flow.
    public init() {}

    /// Stages the history entries built for a pane whose close was approved,
    /// keyed by the pane id (legacy
    /// `pendingPaneCloseHistoryEntries[pane.id] = historyEntries` in
    /// `Workspace.splitTabBar(_:shouldClosePane:)`).
    public func record(_ entries: [Entry], forPane paneId: UUID) {
        pendingEntries[paneId] = entries
    }

    /// Discards any staged history entries for a pane whose close was vetoed,
    /// suppressed, or produced no entries (legacy
    /// `pendingPaneCloseHistoryEntries.removeValue(forKey: pane.id)` on the
    /// confirmation-veto / suppression / empty-entries branches in
    /// `Workspace.splitTabBar(_:shouldClosePane:)`).
    public func clear(forPane paneId: UUID) {
        pendingEntries.removeValue(forKey: paneId)
    }

    /// Removes and returns the staged history entries for a closed pane,
    /// defaulting to an empty array when none were staged (legacy
    /// `pendingPaneCloseHistoryEntries.removeValue(forKey: paneId.id) ?? []` in
    /// `Workspace.splitTabBar(_:didClosePane:)`).
    public func consume(forClosed paneId: UUID) -> [Entry] {
        pendingEntries.removeValue(forKey: paneId) ?? []
    }
}
