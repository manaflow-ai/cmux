/// Authenticated broker boundary that returns current endpoint policy.
public protocol CmxIrohDiscoveryServing: Sendable {
    func discover() async throws -> CmxIrohDiscoveryResponse
}
