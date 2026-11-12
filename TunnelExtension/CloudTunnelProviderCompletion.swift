import CmuxCloudTunnelCore

/// Transfers an immutable NetworkExtension completion into the ordered consumer.
/// Apple's callback is not annotated Sendable but supports asynchronous delivery.
/// Ownership moves to one stream event; only that consumer calls it, once.
final class CloudTunnelProviderCompletion: @unchecked Sendable {
    private let completion: (Error?) -> Void

    init(_ completion: @escaping (Error?) -> Void) { self.completion = completion }

    func call(_ error: CloudTunnelProviderError?) { completion(error) }
}
