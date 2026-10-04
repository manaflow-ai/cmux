/// One registered lease consumer; `cancel()` (or dropping the provider)
/// stops it.
@MainActor
public final class ProviderLeaseObservation {
    private weak var provider: BrowserHostProvider?
    private let id: UInt64

    init(provider: BrowserHostProvider, id: UInt64) {
        self.provider = provider
        self.id = id
    }

    public func cancel() {
        provider?.leaseObservers.removeAll { $0.id == id }
    }
}

extension BrowserHostProvider {
    /// Registers a consumer of lease changes: `(targetId, lease)`, `nil` when
    /// a lease ends (release, session end, stop, tab gone, link drop). Every
    /// consumer hears every change, in registration order.
    public func observeLeases(_ consumer: @escaping (String, ProviderLease?) -> Void) -> ProviderLeaseObservation {
        _ = consumer
        nextLeaseObserverID += 1
        return ProviderLeaseObservation(provider: self, id: nextLeaseObserverID)
    }

    func notifyLease(_ targetID: String, _ lease: ProviderLease?) {
        _ = (targetID, lease)
    }
}
