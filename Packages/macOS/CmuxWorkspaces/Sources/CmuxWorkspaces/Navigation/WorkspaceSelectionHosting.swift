public import Foundation

/// The window-side seam ``WorkspaceSelectionCoordinator`` drives for the
/// selection-navigation effects it cannot own from the package: the actual
/// selection mutation (the legacy private
/// `TabManager.selectWorkspaceId(_:notificationDismissalContext:)`, which sets
/// `selectedTabId` and runs the full selection side-effect chain over the
/// app-target `Workspace` god object), the keyboard-nav sidebar multi-selection
/// collapse (which posts a SwiftUI-binding event through the app-target
/// `SidebarMultiSelectionModel`), and the DEBUG workspace-switch tracing
/// (`cmuxDebugLog` plus the app-target switch-id / start-time bookkeeping).
///
/// The per-window `TabManager` is the single implementer. Splitting it this way
/// keeps the wrap-around order math and the cycle-hot state machine in the
/// package while the `selectedTabId`-mutation chain, the cross-package sidebar
/// model, and the DEBUG instrumentation stay app-side, exactly where those god
/// types live.
///
/// `@MainActor` for the same reason as the coordinator: every selection effect is
/// one main-actor turn driven by a keyboard/menu/CLI gesture, so the host lives
/// where its callers live and no bridging is needed.
@MainActor
public protocol WorkspaceSelectionHosting: AnyObject {
    /// Selects the workspace `id` through the legacy private
    /// `selectWorkspaceId(_:notificationDismissalContext:)` with the
    /// `.explicitWorkspaceResume` context every navigation gesture used.
    ///
    /// The context is constant across all navigation entry points (next, prev,
    /// select-at-index, select-last), so it is baked into the host rather than
    /// passed from the package — keeping the `NotificationDismissalContext` enum
    /// (owned by a sibling package) out of this lift.
    func selectWorkspaceFromNavigation(id: UUID)

    /// Reduces the sidebar multi-selection to the single workspace `workspaceId`
    /// (or clears it when `workspaceId` is not a known tab), then posts the
    /// should-collapse event the SwiftUI binding observes (legacy
    /// `clearSidebarMultiSelection(except:)`). Called from the keyboard-nav paths
    /// so a stale Shift-click range does not survive after the user moves focus.
    func collapseSidebarMultiSelection(except workspaceId: UUID)

    // MARK: DEBUG switch tracing (no-op in release builds)

    /// Primes a pending switch trigger for the next `selectedTabId` change
    /// (legacy DEBUG `debugPrimeWorkspaceSwitchTrigger(_:to:)`). No-op in
    /// release builds.
    func debugPrimeWorkspaceSwitch(trigger: String, to target: UUID?)

    /// Begins a traced workspace switch from `from` to `to` (legacy DEBUG
    /// `debugPrepareWorkspaceSwitch(_:from:to:)`). No-op in release builds.
    func debugPrepareWorkspaceSwitch(trigger: String, from: UUID?, to: UUID?)

    /// Logs that the window entered the cycle-hot state for `generation` (legacy
    /// DEBUG `ws.hot.on`). No-op in release builds.
    func debugLogWorkspaceCycleHotOn(generation: UInt64)

    /// Logs that a pending cooldown was cancelled because a new cycle activation
    /// arrived for `generation` (legacy DEBUG `ws.hot.cancelPrev`). No-op in
    /// release builds.
    func debugLogWorkspaceCycleHotCancelPrevious(generation: UInt64)

    /// Logs that the cooldown sleep itself was cancelled before firing for
    /// `generation` (legacy DEBUG `ws.hot.cooldownCanceled`). No-op in release
    /// builds.
    func debugLogWorkspaceCycleHotCooldownCanceled(generation: UInt64)

    /// Logs that the window left the cycle-hot state for `generation` (legacy
    /// DEBUG `ws.hot.off`). No-op in release builds.
    func debugLogWorkspaceCycleHotOff(generation: UInt64)
}
