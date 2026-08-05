import Foundation

/// Repository for the pull request link destination persisted in `UserDefaults`.
///
/// Isolation: a stateless `Sendable` struct, not an actor. Every reader is a
/// synchronous call path — a sidebar row click, an open-all-pull-requests
/// command, a settings projection — the struct holds no mutable state, and
/// `UserDefaults` is documented thread-safe.
///
/// ```swift
/// let configuration = PullRequestLinkSettingsStore(defaults: defaults).currentConfiguration
/// NSWorkspace.shared.open(configuration.resolvedURL(for: pullRequest.url))
/// ```
public struct PullRequestLinkSettingsStore: Sendable {
    private let sidebar = SidebarCatalogSection()

    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a store reading the given defaults suite.
    ///
    /// - Parameter defaults: The defaults suite holding sidebar settings.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored destination and custom template, resolved against their defaults.
    public var currentConfiguration: PullRequestLinkConfiguration {
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        return PullRequestLinkConfiguration(
            destination: settings.value(for: sidebar.pullRequestLinkDestination),
            customURLTemplate: settings.value(for: sidebar.customPullRequestLinkURLTemplate)
        )
    }
}
