public import Foundation

/// The outcome of `notification.create_for_caller`: delivery to the workspace/
/// surface that best matches the calling terminal, with a multi-signal
/// preference (explicit ids, caller TTY, then the selected workspace).
///
/// The legacy body resolved an active fallback TabManager, then on the main
/// actor picked a target across every window (preferred workspace/surface, the
/// caller's TTY, the selected workspace) and delivered to it. The whole target
/// pick is irreducibly app-coupled (it walks `AppDelegate`/`TabManager`/
/// `Workspace` state), so it stays behind this seam; the coordinator only parses
/// the request and shapes the echoed identity.
public enum ControlNotificationCallerDeliveryResolution: Sendable, Equatable {
    /// No active fallback TabManager resolved (legacy `unavailable` /
    /// "TabManager not available").
    case tabManagerUnavailable
    /// No target workspace resolved (legacy `not_found` / "Workspace not
    /// found", `data: nil`).
    case workspaceNotFound
    /// The notification was delivered. Carries the target workspace id and the
    /// surface it landed on (may be absent → the legacy `NSNull` surface id).
    case delivered(workspaceID: UUID, surfaceID: UUID?)
}
