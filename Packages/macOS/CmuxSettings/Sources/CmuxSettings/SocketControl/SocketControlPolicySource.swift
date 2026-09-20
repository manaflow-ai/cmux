/// Identifies the owner of the effective socket-control value.
public enum SocketControlPolicySource: String, Equatable, Sendable {
    /// A configuration profile forces the app's own preference domain.
    case managedAppDomain = "managed_app_domain"
    /// A tagged/channel build inherits a profile from the release domain.
    case managedReleaseDomain = "managed_release_domain"
    /// The value came from the process environment.
    case environment = "environment"
    /// The value came from the user's settings/defaults.
    case userDefaults = "user_defaults"
}

