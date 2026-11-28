enum TestIrohTransportError: Error, Equatable {
    case unsupported
    case relayUpdateFailed
    case noEndpoint
    case natTraversalAuthorizationFailed
}
