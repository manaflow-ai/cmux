public import CMUXMobileCore

/// Non-secret iOS Iroh runtime state suitable for diagnostics.
public struct CmxIrohClientRuntimeSnapshot: Equatable, Sendable {
    /// The current lifecycle phase.
    public let state: CmxIrohClientRuntimeState

    /// The stable local endpoint identity while active.
    public let endpointID: CmxIrohPeerIdentity?

    /// The broker binding currently authorizing this endpoint.
    public let bindingID: String?

    /// Creates a non-sensitive runtime snapshot.
    ///
    /// - Parameters:
    ///   - state: The current lifecycle phase.
    ///   - endpointID: The active endpoint identity, when available.
    ///   - bindingID: The exact active broker binding, when available.
    public init(
        state: CmxIrohClientRuntimeState,
        endpointID: CmxIrohPeerIdentity?,
        bindingID: String?
    ) {
        self.state = state
        self.endpointID = endpointID
        self.bindingID = bindingID
    }
}
