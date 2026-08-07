/// Provider-scoped incremental topology event.
///
/// Carrying provider identity independently of the mutation lets even a
/// focus-clear event fail closed after a connection generation changes.
public struct NestedTopologyEvent: Codable, Equatable, Sendable {
    /// Provider connection generation that emitted the change.
    public let provider: NestedProviderIdentity

    /// Typed topology mutation.
    public let change: NestedTopologyChange

    /// Creates a provider-scoped topology event.
    ///
    /// - Parameters:
    ///   - provider: Provider generation that emitted the event.
    ///   - change: Typed topology mutation.
    public init(provider: NestedProviderIdentity, change: NestedTopologyChange) {
        self.provider = provider
        self.change = change
    }
}
