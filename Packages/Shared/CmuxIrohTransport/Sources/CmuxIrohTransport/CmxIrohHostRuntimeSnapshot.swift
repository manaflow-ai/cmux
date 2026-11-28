public import CMUXMobileCore

/// Non-secret state exposed by the host runtime.
public struct CmxIrohHostRuntimeSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case inactive
        case starting
        case active
        case stopping
        case signingOut
        case quarantined
        case failed
    }

    public let state: State
    public let endpointID: CmxIrohPeerIdentity?
    public let bindingID: String?

    public init(
        state: State,
        endpointID: CmxIrohPeerIdentity?,
        bindingID: String?
    ) {
        self.state = state
        self.endpointID = endpointID
        self.bindingID = bindingID
    }
}
