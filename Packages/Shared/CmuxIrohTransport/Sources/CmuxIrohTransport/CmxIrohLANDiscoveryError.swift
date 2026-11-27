public enum CmxIrohLANDiscoveryError: Error, Equatable, Sendable {
    case invalidSocketAddress
    case invalidInterface
    case invalidAdvertisement
    case invalidTXTRecord
    case staleAdvertisement
    case ambiguousBinding
    case policyDenied
    case serviceFailure(Int32)
}
