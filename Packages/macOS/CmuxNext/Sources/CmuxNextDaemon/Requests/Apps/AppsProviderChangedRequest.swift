/// Tells the supervisor that the data of one provided family changed, so app subscribers of
/// `<family>.changed` read it again. Carries no rows: each app reads with its own grant.
public nonisolated struct AppsProviderChangedRequest: DaemonRequest {
    /// Empty acknowledgement.
    public typealias Response = EmptyResponse
    /// Native provider change notice.
    public static let command = "apps-provider-changed"
    /// Daemons that publish `<family>.changed` for a provider.
    public static let requiredCapability: String? = "app-provider-changed-v1"
    /// The family this connection registered (for example `agent_chat`).
    public let family: String

    /// Creates a change notice for one family this provider holds.
    /// - Parameter family: A family from this connection's `apps-provider-register`.
    public init(family: String) { self.family = family }
}
