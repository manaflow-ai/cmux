public import Foundation

/// Read-and-act seam the host fills so ``CommandPaletteCoordinator`` can own the
/// command palette's present / dismiss / open-request state machine without
/// importing any app-target window, panel, focus, or AppKit type.
///
/// The coordinator owns the window-agnostic transitions: it drives the
/// ``CommandPalettePresentationModel`` (mode/query/draft/selection/scroll resets,
/// the queued activation and text-selection clears, the results-revision bump)
/// and its own results-pipeline bookkeeping (the search-request id, the
/// resolved-search trackers, the search-pending flag, the corpus/results
/// resets). Everything that requires the host's concrete focus model, AppKit
/// first responder, app `@State`/`@FocusState`, the search/probe cancellation
/// helpers, or the app/UI-package DEBUG helpers stays on the conformer side
/// (`ContentView`) and is reached through this protocol:
///
/// - Reading and flipping the per-window "palette presented" flag.
/// - Capturing the focus-restore target from the live focused panel, reading and
///   clearing it, and requesting a post-dismiss focus restore against it (the
///   target type is the host's app-target value, carried as ``FocusRestoreTarget``).
/// - Refreshing the cached default-terminal status and the persisted usage
///   history, clearing the forkable-agent probe's active panel key, and
///   canceling the in-flight search, the search-index build, and the
///   forkable-agent availability probe.
/// - Clearing the search/rename `@FocusState` flags, resetting search focus,
///   clearing the terminal open-target availability set, clearing the window's
///   first responder, scheduling a results refresh, syncing the overlay command
///   list, and syncing the per-window debug state.
/// - Supplying the default workspace-description editor height, the observed
///   window's debug summary, and the DEBUG log sink, all of which live in the
///   app/UI target.
///
/// Mirroring the package's other palette seams, the host is a value-typed
/// SwiftUI `View` that is reconstructed every render, so the coordinator never
/// stores it: each driving method takes the current host.
///
/// ## Isolation
///
/// Every requirement is `@MainActor`: shortcut routing, SwiftUI visibility sync,
/// keyboard handling, and socket-driven simulation all hop to main before
/// touching palette state, so the coordinator runs the whole machine on the main
/// actor with no actor hop.
@MainActor
public protocol CommandPaletteLifecycleHost {
    /// The host's app-target focus-restore target value (an opaque carrier the
    /// coordinator only captures, forwards, and clears).
    associatedtype FocusRestoreTarget

    /// Whether the command palette is currently presented in the host window.
    var commandPaletteLifecycleIsPresented: Bool { get }

    /// The default initial height for the workspace-description editor, owned by
    /// the app/UI target's multiline text editor representable.
    var commandPaletteLifecycleDefaultWorkspaceDescriptionHeight: CGFloat { get }

    /// Flips the per-window "palette presented" flag.
    func commandPaletteLifecycleSetPresented(_ value: Bool)

    /// Captures the focus-restore target from the live focused panel (or clears
    /// it when no panel is focused), storing it for a later restore.
    func commandPaletteLifecycleCaptureFocusRestoreTarget()

    /// The currently stored focus-restore target, or `nil` when none is held.
    func commandPaletteLifecycleCurrentRestoreFocusTarget() -> FocusRestoreTarget?

    /// Clears the stored focus-restore target.
    func commandPaletteLifecycleClearRestoreFocusTarget()

    /// Requests a post-dismiss focus restore against `target`.
    func commandPaletteLifecycleRequestFocusRestore(target: FocusRestoreTarget)

    /// Refreshes the cached default-terminal registration status without
    /// rebuilding the search corpus.
    func commandPaletteLifecycleRefreshCachedDefaultTerminalStatus()

    /// Reloads the persisted per-command usage history.
    func commandPaletteLifecycleRefreshUsageHistory()

    /// Clears the forkable-agent probe's active panel key.
    func commandPaletteLifecycleClearForkableProbeActivePanelKey()

    /// Cancels the in-flight palette search.
    func commandPaletteLifecycleCancelSearch()

    /// Cancels the in-flight search-index build.
    func commandPaletteLifecycleCancelSearchIndexBuild()

    /// Cancels the in-flight forkable-agent availability probe.
    func commandPaletteLifecycleCancelForkableAgentAvailabilityProbe()

    /// Sets the per-window "should focus the workspace-description editor" flag.
    func commandPaletteLifecycleSetShouldFocusWorkspaceDescriptionEditor(_ value: Bool)

    /// Clears the search input `@FocusState` flag.
    func commandPaletteLifecycleClearSearchFocused()

    /// Clears the rename input `@FocusState` flag.
    func commandPaletteLifecycleClearRenameFocused()

    /// Clears the cached terminal open-target availability set.
    func commandPaletteLifecycleClearTerminalOpenTargetAvailability()

    /// Schedules a results refresh, rebuilding the search corpus when forced.
    func commandPaletteLifecycleScheduleResultsRefresh(forceSearchCorpusRefresh: Bool)

    /// Synchronizes the overlay command-list render state.
    func commandPaletteLifecycleSyncOverlayCommandListState()

    /// Resets the search input focus.
    func commandPaletteLifecycleResetSearchFocus()

    /// Clears the observed window's first responder.
    func commandPaletteLifecycleClearFirstResponderAndBrowserFocus()

    /// Synchronizes the per-window palette debug state for the observed window.
    func commandPaletteLifecycleSyncDebugState()

    /// The observed window's debug summary, for DEBUG diagnostics.
    func commandPaletteLifecycleObservedWindowDebugSummary() -> String

    /// Emits a DEBUG diagnostic line (a no-op in release builds).
    func commandPaletteLifecycleDebugLog(_ message: @autoclosure () -> String)
}
