public import Foundation

/// The per-window focus-history seam the app target consumes: recording,
/// suppression, invalidation, menu snapshots, and back/forward navigation.
@MainActor
public protocol FocusHistoryNavigating: AnyObject {
    /// Wires the window-side host. Call before the first workspace is added
    /// so the initial selection's recording reaches the model.
    func attach(host: any FocusHistoryHosting)

    /// Whether focus changes are currently recorded (recording is not
    /// suppressed).
    var shouldRecordFocusHistory: Bool { get }
    /// Runs `body` with focus-history recording suppressed (re-entrant).
    @discardableResult
    func withFocusHistoryRecordingSuppressed<Result>(_ body: () throws -> Result) rethrows -> Result

    /// Records a focus landing on the workspace/panel. With
    /// `preservingForwardBranch` the forward stack is kept and the entry is
    /// inserted after the current position (the closed-item restore path).
    func recordFocusInHistory(workspaceId: UUID, panelId: UUID?, preservingForwardBranch: Bool)
    /// Records the entry when non-nil; see
    /// ``recordFocusInHistory(workspaceId:panelId:preservingForwardBranch:)``.
    func recordFocusInHistory(_ entry: FocusHistoryEntry?, preservingForwardBranch: Bool)
    /// Records an implicit (non-user-initiated) focus: coalesces with the
    /// current entry when it targets the same workspace mid-stack.
    func recordImplicitFocusInHistory(workspaceId: UUID, panelId: UUID?)

    /// Drops the workspace's entries (panel `nil`) or bumps the revision so
    /// menus revalidate a panel-level entry.
    func invalidateFocusHistoryTarget(workspaceId: UUID, panelId: UUID?)

    /// Resolves the entry's panel against the workspace's current panels
    /// using the legacy fallback chain (entry panel, remembered panel,
    /// workspace-focused panel, deterministic first).
    func resolvedFocusHistoryPanelId(for entry: FocusHistoryEntry) -> UUID?
    /// The entry for the current selection, if any workspace is selected.
    var currentFocusHistoryEntry: FocusHistoryEntry? { get }

    /// Builds the back or forward menu snapshot, optionally truncated.
    func focusHistoryMenuSnapshot(direction: FocusHistoryMenuDirection, maxItemCount: Int?) -> FocusHistoryMenuSnapshot
    /// Navigates to a menu item; returns whether navigation happened.
    @discardableResult
    func navigateToFocusHistoryMenuItem(_ item: FocusHistoryMenuItem) -> Bool
    /// Navigates one step back; returns whether navigation happened.
    @discardableResult
    func navigateBack() -> Bool
    /// Navigates one step forward; returns whether navigation happened.
    @discardableResult
    func navigateForward() -> Bool
    /// Whether any back entry is navigable from the current position.
    var canNavigateBack: Bool { get }
    /// Whether any forward entry is navigable from the current position.
    var canNavigateForward: Bool { get }

    /// Marks a selection-side-effect generation whose deferred side effects
    /// must run with recording suppressed.
    func markSuppressedSelectionSideEffectGeneration(_ generation: UInt64)
    /// Consumes the mark for the generation; returns whether it was set.
    func consumeSuppressedSelectionSideEffectGeneration(_ generation: UInt64) -> Bool

    /// Clears all history state (the window-reset path). Does not bump the
    /// host revision; the reset path owns that bump.
    func reset()
}
