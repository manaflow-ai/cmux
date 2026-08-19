import Foundation

/// Where the host's live backend-environment switch currently is.
///
/// A package-local mirror of the host's switch-transaction phase:
/// `CmuxSettingsUI` deliberately does not link the host's auth runtime, so
/// the host's ``AccountFlow`` implementation maps its own phase type to this
/// one. ``BackendEnvironmentCard`` replaces the picker with a progress row
/// during the transitional phases and shows a switched note at ``finished``.
public enum AccountBackendEnvironmentSwitchPhase: Equatable, Sendable {
    /// No switch in progress; the picker is interactive.
    case idle
    /// Signing out of the old environment (its defaults still active).
    case signingOut
    /// Override committed; the host is rebuilding its auth stack for the
    /// new environment.
    case retargeting
    /// Switch complete; the card shows the switched note until the host
    /// flow's ``AccountFlow/resetBackendEnvironmentSwitchPhase()`` runs.
    case finished
}
