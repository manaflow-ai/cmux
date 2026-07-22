public import Foundation

/// Publishes typed profile lifecycle and navigation changes.
public enum BrowserWebExtensionUpdate: Equatable, Sendable {
    /// The runtime entered a new explicit lifecycle phase.
    case phaseChanged(BrowserWebExtensionPhase)

    /// A queued navigation may execute exactly once.
    case navigationReleased(
        BrowserWebExtensionNavigationIntent,
        BrowserWebExtensionNavigationReleaseReason
    )

    /// A queued navigation was removed before it could execute.
    case navigationCancelled(UUID)

    /// An extension toolbar action changed for a profile or panel.
    case actionChanged(BrowserWebExtensionActionUpdate)

    /// Installed extensions or load failures changed for a profile.
    case snapshotInvalidated(UUID)

    /// An extension is awaiting an explicit optional-permission decision.
    case permissionRequested(BrowserWebExtensionPermissionRequest)
}
