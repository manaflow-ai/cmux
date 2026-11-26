/// One broker-managed relay advertised by a verified signed policy.
public struct CmxIrohManagedRelayDescriptor: Equatable, Sendable {
    /// Stable identifier used by local user selection.
    public let id: String

    /// Stable provider identifier such as `cmux` or `n0`.
    public let provider: String

    /// Provider-defined region identifier used for diagnostics and selection UI.
    public let region: String

    /// Canonical HTTPS relay origin.
    public let url: String

    init(id: String, provider: String, region: String, url: String) {
        self.id = id
        self.provider = provider
        self.region = region
        self.url = url
    }
}
