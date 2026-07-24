public import Foundation

/// The outcome of a workspace remote mutation that resolves a workspace by id
/// (with a selected-workspace fallback), acts on it, and echoes its remote
/// status. Shared by `workspace.remote.configure` / `disconnect` / `reconnect`
/// / `foreground_auth_ready` / `status`.
///
/// The coordinator has already validated the `workspace_id` shape and the
/// per-method inputs; it also resolves the workspace id (a present-but-null
/// fallback to the routed selected workspace) before calling the seam, so
/// `missingWorkspaceID` here is the legacy "Missing workspace_id"
/// `invalid_params` after the fallback also yielded nothing.
public enum ControlWorkspaceRemoteResolution: Sendable, Equatable {
    /// Neither an explicit nor a fallback workspace id resolved (legacy
    /// `invalid_params` / "Missing workspace_id").
    case missingWorkspaceID
    /// The workspace was not found (legacy `not_found` / "Workspace not found",
    /// data carries the workspace identity). Carries the resolved workspace id
    /// for that payload.
    case notFound(workspaceID: UUID)
    /// The remote workspace is not configured (legacy `invalid_state` /
    /// "Remote workspace is not configured", `reconnect` only). Carries the
    /// resolved workspace id for that payload.
    case notConfigured(workspaceID: UUID)
    /// The mutation succeeded. Carries the owning window id (may be absent), the
    /// resolved workspace id, and the bridged `remoteStatusPayload()`.
    case resolved(windowID: UUID?, workspaceID: UUID, remoteStatus: JSONValue)
}
