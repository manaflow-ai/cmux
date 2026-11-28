import Foundation

/// Resolves the canonical workspace/surface identity to stamp into a spawned agent's environment.
///
/// cmux's CLI agent launchers (the `claude-teams` / `oh-my-codex` / `codex-teams` family) run inside a
/// terminal surface and inherit that surface's own `CMUX_SURFACE_ID` / `CMUX_WORKSPACE_ID`. They also
/// query the daemon for the operator's currently *focused* pane (for the tmux-compat shim). The agent's
/// canonical identity must come from the launch surface, **not** the focused pane: stamping the focused
/// pane desyncs `CMUX_SURFACE_ID` from the inherited `CMUX_PANEL_ID`, so an agent launched in surface B
/// while surface A is focused records surface A and later restores into the wrong surface
/// (https://github.com/manaflow-ai/cmux/issues/4920, the codex "jumble after reload" symptom).
///
/// This type is a stateless value; construct one at the call site (`AgentSpawnIdentity()`).
///
/// ```swift
/// // Launcher runs in surface B while the operator's focus is on surface A:
/// AgentSpawnIdentity().resolve(
///     ownWorkspaceId: "WS-B", ownSurfaceId: "B",
///     focusedWorkspaceId: "WS-A", focusedSurfaceId: "A"
/// ) // == (workspaceId: "WS-B", surfaceId: "B")  — the launch surface, not the focused pane
/// ```
public struct AgentSpawnIdentity: Sendable, Equatable {
    /// Creates a spawn-identity resolver. The type holds no state.
    public init() {}

    /// The canonical `(workspaceId, surfaceId)` to stamp, preferring the launcher's own identity.
    ///
    /// The launching process's own identity wins whenever present; the focused pane is only a fallback
    /// for launches that have no own identity (e.g. started outside a cmux-managed terminal). Inputs are
    /// trimmed and empty values are treated as absent.
    ///
    /// The result is always a *coherent pair*: the surface always belongs to the resolved workspace. The
    /// focused surface is borrowed only when the focused pane is in that same workspace, so a launcher
    /// that inherits only `CMUX_WORKSPACE_ID` (no surface) while focus is in a *different* workspace
    /// never produces an impossible `(own workspace, focused surface)` pair — which the daemon would
    /// reject, dropping the hook. In that partial case the surface is left `nil` so the hook's PID/TTY
    /// resolution picks the agent's real pane.
    ///
    /// - Parameters:
    ///   - ownWorkspaceId: the launching process's inherited `CMUX_WORKSPACE_ID` (the launch surface).
    ///   - ownSurfaceId: the launching process's inherited `CMUX_SURFACE_ID` (the launch surface).
    ///   - focusedWorkspaceId: the operator's currently focused workspace id (fallback only).
    ///   - focusedSurfaceId: the operator's currently focused surface id (fallback only).
    /// - Returns: the workspace/surface ids to stamp; either element is `nil` when no source provides a
    ///   value that pairs coherently with the resolved workspace.
    public func resolve(
        ownWorkspaceId: String?,
        ownSurfaceId: String?,
        focusedWorkspaceId: String?,
        focusedSurfaceId: String?
    ) -> (workspaceId: String?, surfaceId: String?) {
        let ownWorkspace = normalized(ownWorkspaceId)
        let ownSurface = normalized(ownSurfaceId)
        let focusedWorkspace = normalized(focusedWorkspaceId)
        let workspaceId = ownWorkspace ?? focusedWorkspace

        let surfaceId: String?
        if let ownSurface, ownWorkspace != nil {
            // The own surface is the launch identity, authoritative only paired with its own workspace.
            // An orphan own surface (inherited CMUX_SURFACE_ID with no CMUX_WORKSPACE_ID, e.g. partial
            // env scrubbing) has an unknown workspace, so it is not trusted against the focused context.
            surfaceId = ownSurface
        } else if let focusedSurface = normalized(focusedSurfaceId), focusedWorkspace == workspaceId {
            // Borrow the focused surface only when the focused pane is in the resolved workspace, so we
            // never stamp a surface from a different workspace. Otherwise leave it for PID/TTY resolution.
            surfaceId = focusedSurface
        } else {
            surfaceId = nil
        }
        return (workspaceId, surfaceId)
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
