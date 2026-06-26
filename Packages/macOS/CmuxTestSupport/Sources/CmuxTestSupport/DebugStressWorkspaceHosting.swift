#if DEBUG
public import Foundation

/// The live-state seam for the DEBUG stress-workspace harness.
///
/// ``DebugStressWorkspaceDriver`` owns the harness orchestration: the creation
/// loop, the per-workspace and per-surface timing, the stats accumulation, the
/// generic notification-driven wait primitive, and every `stress.setup.*` /
/// `NSLog` line. None of that touches an app type. The operations that *do*
/// touch live state (creating a `Workspace`, building its split layout, forcing
/// AppKit layout, enumerating terminal panels, starting their Ghostty surfaces)
/// cannot cross the package boundary, so the app target conforms this protocol
/// and the driver calls back into it.
///
/// The driver never names a `Workspace`, a pane, a tab, or a terminal panel: it
/// addresses created workspaces by ``DebugStressWorkspaceHandle`` and queued
/// surfaces by ``DebugStressLoadTargetHandle`` — opaque tokens the host mints
/// and interprets. The host keeps the only mapping from a token back to its live
/// object.
///
/// The seam is `#if DEBUG` only, matching the legacy block it was extracted
/// from: the harness exists purely to measure performance at workspace scale and
/// is compiled out of release builds.
///
/// Isolation: `@MainActor`, because every operation reads and mutates
/// main-actor workspace / window / terminal-surface state.
@MainActor
public protocol DebugStressWorkspaceHosting: AnyObject {
    /// Whether the harness can run right now. Mirrors the legacy
    /// `guard let tabManager` precondition: `false` when there is no live tab
    /// manager to create workspaces in, in which case the driver does nothing
    /// (not even enabling the lag probe).
    var canRunStressHarness: Bool { get }

    /// Turns on the input-lag probe so subsequent keystrokes are timed while the
    /// stress batch is live. (The probe state and its slow-keystroke logger stay
    /// in the app; the driver only flips it on at batch start.)
    func enableStressLagProbe()

    /// The id of the currently selected workspace, captured so it can be
    /// restored after the batch is built. Returns `nil` when nothing is
    /// selected.
    func currentSelectedWorkspaceID() -> UUID?

    /// Restores selection to `id` if a workspace with that id still exists.
    func restoreSelectedWorkspace(_ id: UUID)

    /// Creates one stress workspace appended at the end of the tab strip, titled
    /// with the configured prefix and `oneBasedIndex`, and returns its handle.
    func createStressWorkspace(oneBasedIndex: Int) -> DebugStressWorkspaceHandle

    /// Builds the four-pane split layout with `tabsPerPane` terminal tabs in the
    /// workspace identified by `handle`, yielding to the run loop every
    /// `yieldInterval` inner iterations. Returns `false` if the layout could not
    /// be built exactly as requested.
    func configureStressWorkspaceLayout(
        _ handle: DebugStressWorkspaceHandle,
        paneCount: Int,
        tabsPerPane: Int,
        yieldInterval: Int
    ) async -> Bool

    /// Number of terminal surfaces not yet loaded across `handles`.
    func pendingTerminalSurfaceCount(in handles: [DebugStressWorkspaceHandle]) -> Int

    /// Retains the batch's workspaces so their terminal loads are not torn down
    /// while the harness forces them to mount.
    func retainStressWorkspaceLoads(_ handles: [DebugStressWorkspaceHandle])

    /// Releases the retain taken by ``retainStressWorkspaceLoads(_:)``.
    func releaseStressWorkspaceLoads(_ handles: [DebugStressWorkspaceHandle])

    /// Forces the active window (or, failing that, every window) to lay out and
    /// display so off-screen terminal surfaces are given a real geometry.
    func forceStressVisibleLayout()

    /// Reconciles geometry / requests background surface starts for `handles`
    /// and reports how many of them now have a mounted terminal view or surface.
    /// Used by the mount-readiness wait.
    func mountedStressWorkspaceCount(in handles: [DebugStressWorkspaceHandle]) -> Int

    /// Preloads each terminal panel in `handles` and returns one queued
    /// ``DebugStressLoadTargetHandle`` per panel that began loading, in
    /// workspace order. `perWorkspace` is invoked after each workspace's panels
    /// are queued so the driver can yield and log progress.
    func queueStressTerminalLoadTargets(
        in handles: [DebugStressWorkspaceHandle],
        perWorkspace: (_ workspaceIndex: Int, _ queuedSoFar: Int) async -> Void
    ) async -> [DebugStressLoadTargetHandle]

    /// Issues one surface-start pass over `targets`: requests a background
    /// surface start for each still-unloaded target, returns the targets that
    /// remain pending plus how many starts were issued this pass.
    func refreshStressPendingTargets(
        _ targets: [DebugStressLoadTargetHandle]
    ) -> (pending: [DebugStressLoadTargetHandle], started: Int)

    /// Installs the terminal-surface-readiness notification observers, invoking
    /// `trigger` (on the main queue) whenever one fires, and returns the
    /// observer tokens for later removal. Mirrors the legacy observer set
    /// (`terminalSurfaceDidBecomeReady`, `terminalSurfaceHostedViewDidMoveToWindow`,
    /// `NSWindow.didUpdateNotification`).
    func installStressSurfaceReadinessObservers(
        trigger: @escaping () -> Void
    ) -> [any NSObjectProtocol]

    /// Removes observers previously installed by
    /// ``installStressSurfaceReadinessObservers(trigger:)``.
    func removeStressSurfaceReadinessObservers(_ tokens: [any NSObjectProtocol])

    /// A short, prefixed identifier for `handle` used only in timeout log lines.
    func logIdentifier(for handle: DebugStressLoadTargetHandle) -> String
}
#endif
