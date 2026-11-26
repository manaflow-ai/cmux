/// Identifies which preference domain supplied a profile-forced value.
public enum ManagedDevicePolicyValueSource: String, Equatable, Sendable {
    /// The running app's own preference domain.
    case appDomain = "app_domain"
    /// The release payload domain inherited by tagged/channel builds.
    case releaseDomain = "release_domain"
}
