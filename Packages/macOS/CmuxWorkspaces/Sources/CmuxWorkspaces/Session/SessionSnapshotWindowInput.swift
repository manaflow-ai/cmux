/// One window's contribution to the persisted session snapshot, flattened by the
/// app-side ``SessionSnapshotBuilding`` host so the package
/// ``SessionSnapshotBuilder`` can apply the window-assembly policy without
/// reaching into live god state.
///
/// `Window` is the app-target per-window snapshot value type
/// (`SessionWindowSnapshot`); the package stays generic over it because that DTO
/// and its `AppSessionSnapshot` wrapper are owned by the executable target.
///
/// ``dropsWhenEmptyDedicatedRemoteWindow`` is the host's already-evaluated answer
/// to the legacy guard `remoteTmuxController.isDedicatedRemoteWindow(windowId)
/// && snapshot.tabManager.workspaces.isEmpty`: a dedicated remote-tmux mirror
/// window with no surviving workspaces is dropped, since it needs a live SSH
/// control connection and must not restore as an empty shell.
///
/// ``dropsWhenCrashDiagnosticWindowRemoved`` and
/// ``removedCrashDiagnosticState`` carry the app-side crash-diagnostic pruning
/// result. The app owns the policy because it can inspect the app-target
/// session snapshot DTOs; the package only folds the already-pruned inputs.
public struct SessionSnapshotWindowInput<Window>: Sendable where Window: Sendable {
    /// This window's flattened per-window snapshot value.
    public let snapshot: Window

    /// Whether this window must be dropped because it is a dedicated remote-tmux
    /// window whose snapshot has no surviving workspaces.
    public let dropsWhenEmptyDedicatedRemoteWindow: Bool

    /// Whether this window must be dropped because crash-diagnostic pruning
    /// removed the whole window.
    public let dropsWhenCrashDiagnosticWindowRemoved: Bool

    /// Whether crash-diagnostic state was removed while preparing this window.
    public let removedCrashDiagnosticState: Bool

    /// Creates a per-window snapshot input.
    ///
    /// - Parameters:
    ///   - snapshot: this window's flattened per-window snapshot value.
    ///   - dropsWhenEmptyDedicatedRemoteWindow: whether the window must be dropped
    ///     (empty dedicated remote-tmux window).
    ///   - dropsWhenCrashDiagnosticWindowRemoved: whether the window must be
    ///     dropped because crash-diagnostic pruning removed the whole window.
    ///   - removedCrashDiagnosticState: whether crash-diagnostic state was
    ///     removed while preparing this window.
    public init(
        snapshot: Window,
        dropsWhenEmptyDedicatedRemoteWindow: Bool,
        dropsWhenCrashDiagnosticWindowRemoved: Bool = false,
        removedCrashDiagnosticState: Bool = false
    ) {
        self.snapshot = snapshot
        self.dropsWhenEmptyDedicatedRemoteWindow = dropsWhenEmptyDedicatedRemoteWindow
        self.dropsWhenCrashDiagnosticWindowRemoved = dropsWhenCrashDiagnosticWindowRemoved
        self.removedCrashDiagnosticState = removedCrashDiagnosticState
    }
}
